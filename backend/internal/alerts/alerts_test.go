package alerts

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/oauth2"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
	"github.com/dilshadahmad2/nearby-live/backend/internal/live"
)

var home = geo.Point{Lat: 28.654, Lon: 77.241}

func ip(v int) *int { return &v }

func trainAt(id string, km float64, delay *int) live.Object {
	p := geo.Point{Lat: home.Lat + km/111.2, Lon: home.Lon}
	return live.Object{ID: id, Kind: live.KindTrain, Label: id, Name: "Rajdhani", Point: p, DelayMin: delay, FixTime: time.Now()}
}

func TestEvaluateRules(t *testing.T) {
	s := Subscription{DeviceToken: "tok-12345", Location: home, TrainKm: 2, FlightKm: 3, LateMin: 30, TrainNumbers: []string{"12951"}}
	alt := 2500.0
	objs := []live.Result{
		{Object: trainAt("12951", 1.5, ip(45))}, // watched, near and late → 2 events
		{Object: trainAt("11111", 1.0, nil)},    // near but not watched → none
		{Object: trainAt("12951b", 5, ip(90))},  // far, not watched
		{Object: live.Object{ID: "abc", Kind: live.KindFlight, Label: "AIC138", Point: home, AltitudeM: &alt}},
		{Object: live.Object{ID: "gnd", Kind: live.KindFlight, Label: "IGO1", Point: home, OnGround: true}},
	}
	got := Evaluate(s, objs)
	keys := map[string]string{}
	for _, e := range got {
		keys[e.Key] = e.Body
	}
	if len(got) != 3 {
		t.Fatalf("events = %+v", got)
	}
	if !strings.Contains(keys["train-near:12951"], "1.5 km away · 45 min late") {
		t.Fatalf("near body: %q", keys["train-near:12951"])
	}
	if _, ok := keys["train-late:12951:3"]; !ok {
		t.Fatalf("late key missing: %v", keys)
	}
	if !strings.Contains(keys["flight-near:abc"], "AIC138") {
		t.Fatalf("flight: %v", keys)
	}
	// Empty watch list = any train is announced.
	s.TrainNumbers = nil
	if n := len(Evaluate(s, objs[:2])); n != 2 {
		t.Fatalf("any-train events = %d", n)
	}
}

func TestQuietHoursWrapMidnight(t *testing.T) {
	s := Subscription{QuietStart: 22, QuietEnd: 7, TZOffsetMin: 330}
	at := func(h int) time.Time { return time.Date(2026, 11, 7, h, 0, 0, 0, time.FixedZone("IST", 330*60)) }
	for h, want := range map[int]bool{21: false, 22: true, 2: true, 6: true, 7: false, 12: false} {
		if got := s.quiet(at(h)); got != want {
			t.Errorf("hour %d quiet=%v want %v", h, got, want)
		}
	}
}

type recNotifier struct {
	mu   sync.Mutex
	got  []Event
	fail error
}

func (r *recNotifier) Send(_ context.Context, _ Subscription, e Event) error {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.fail != nil {
		return r.fail
	}
	r.got = append(r.got, e)
	return nil
}

func TestWorkerDedupesAndDropsInvalidTokens(t *testing.T) {
	hub := live.NewHub()
	hub.Replace(live.KindTrain, "test", []live.Object{trainAt("12951", 1, nil)})
	store := &MemStore{}
	_ = store.Put(context.Background(), Subscription{DeviceToken: "tok-12345", Location: home, TrainKm: 2, QuietStart: -1, QuietEnd: -1})
	n := &recNotifier{}
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, time.UTC)
	w := &Worker{Hub: hub, Store: store, Notifier: n, Cooldown: time.Hour, Now: func() time.Time { return now }}

	w.Tick(context.Background())
	w.Tick(context.Background()) // within cooldown → no repeat
	if len(n.got) != 1 || w.Sent() != 1 {
		t.Fatalf("sent %d", len(n.got))
	}
	now = now.Add(61 * time.Minute)
	w.Tick(context.Background())
	if len(n.got) != 2 {
		t.Fatalf("after cooldown sent %d", len(n.got))
	}

	n.fail = ErrInvalidToken
	now = now.Add(2 * time.Hour)
	w.Tick(context.Background())
	if _, ok, _ := store.Get(context.Background(), "tok-12345"); ok {
		t.Fatal("invalid token should be removed")
	}
}

func TestWorkerRetriesAfterSendError(t *testing.T) {
	hub := live.NewHub()
	hub.Replace(live.KindTrain, "test", []live.Object{trainAt("12951", 1, nil)})
	store := &MemStore{}
	_ = store.Put(context.Background(), Subscription{DeviceToken: "tok-12345", Location: home, TrainKm: 2, QuietStart: -1, QuietEnd: -1})
	n := &recNotifier{fail: errors.New("boom")}
	w := &Worker{Hub: hub, Store: store, Notifier: n}
	w.Tick(context.Background())
	n.fail = nil
	w.Tick(context.Background())
	if len(n.got) != 1 {
		t.Fatalf("expected retry, sent %d", len(n.got))
	}
}

func TestFCMRequestAndUnregistered(t *testing.T) {
	var body map[string]any
	var auth string
	unregistered := false
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth = r.Header.Get("Authorization")
		if r.URL.Path != "/v1/projects/demo-proj/messages:send" {
			t.Errorf("path %s", r.URL.Path)
		}
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &body)
		if unregistered {
			w.WriteHeader(http.StatusNotFound)
			w.Write([]byte(`{"error":{"status":"NOT_FOUND","details":[{"errorCode":"UNREGISTERED"}]}}`))
			return
		}
		w.Write([]byte(`{"name":"projects/demo-proj/messages/1"}`))
	}))
	defer srv.Close()
	f := &FCM{ProjectID: "demo-proj", BaseURL: srv.URL,
		Tokens: oauth2.StaticTokenSource(&oauth2.Token{AccessToken: "at", TokenType: "Bearer"})}
	s := Subscription{DeviceToken: "device-abc"}
	e := Event{Key: "train-near:12951", Title: "Train nearby", Body: "…", Data: map[string]string{"kind": "train"}}
	if err := f.Send(context.Background(), s, e); err != nil {
		t.Fatal(err)
	}
	m := body["message"].(map[string]any)
	if auth != "Bearer at" || m["token"] != "device-abc" || m["notification"].(map[string]any)["title"] != "Train nearby" {
		t.Fatalf("request: auth=%q body=%v", auth, body)
	}
	if m["data"].(map[string]any)["kind"] != "train" {
		t.Fatalf("data: %v", m["data"])
	}
	unregistered = true
	if err := f.Send(context.Background(), s, e); !errors.Is(err, ErrInvalidToken) {
		t.Fatalf("err = %v, want invalid token", err)
	}
}
