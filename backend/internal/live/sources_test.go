package live

import (
	"context"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

func TestWeatherRefresherCachesPerCell(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Query().Get("current") == "" {
			t.Errorf("missing current= in %s", r.URL)
		}
		w.Write([]byte(`{"current": {"temperature_2m": 27.6, "relative_humidity_2m": 62, "wind_speed_10m": 11.9,
			"precipitation_probability": 10, "weather_code": 2}}`))
	}))
	defer srv.Close()
	h := NewHub()
	wx := &Weather{Hub: h, BaseURL: srv.URL}
	p := geo.Point{Lat: 28.654, Lon: 77.241}

	wx.EnsureFresh(context.Background(), p, 2, 3*time.Second)
	wx.EnsureFresh(context.Background(), geo.Point{Lat: 28.656, Lon: 77.243}, 2, 3*time.Second) // same cell
	if calls.Load() != 1 {
		t.Fatalf("calls = %d, want 1 per cell", calls.Load())
	}
	// A 2 km query still gets the nearest weather cell.
	got := h.FindArea(Query{Center: &p, RadiusKm: 2, Kinds: []Kind{KindWeather}})
	if len(got) != 1 || got[0].Status != "Partly Cloudy" || got[0].Extra["temperature_c"] != 27.6 || got[0].Extra["humidity_pct"] != 62 {
		t.Fatalf("weather = %+v", got)
	}
}

const tomtomBody = `{"flowSegmentData": {"frc": "FRC2", "currentSpeed": 12, "freeFlowSpeed": 45, "roadClosure": false,
	"coordinates": {"coordinate": [
		{"latitude": 28.651, "longitude": 77.240}, {"latitude": 28.652, "longitude": 77.242}, {"latitude": 28.653, "longitude": 77.244}]}}}`

func TestParseTomTomFlow(t *testing.T) {
	o, err := ParseTomTomFlow([]byte(tomtomBody))
	if err != nil || o == nil {
		t.Fatalf("o=%v err=%v", o, err)
	}
	if o.Status != "heavy" || o.Label != "Main Road" || o.Point != (geo.Point{Lat: 28.652, Lon: 77.242}) {
		t.Fatalf("segment = %+v", o)
	}
	if c := o.Extra["coordinates"].([][2]float64); len(c) != 3 || c[0] != [2]float64{77.240, 28.651} {
		t.Fatalf("coordinates = %v", c)
	}
	if o, _ := ParseTomTomFlow([]byte(`{"flowSegmentData": {"currentSpeed": 1}}`)); o != nil {
		t.Fatal("no geometry should give nil")
	}
	for _, c := range []struct {
		cur, free float64
		want      string
	}{{50, 50, "free"}, {35, 50, "light"}, {25, 50, "moderate"}, {10, 50, "heavy"}} {
		if got := Congestion(c.cur, c.free, false); got != c.want {
			t.Errorf("Congestion(%v,%v) = %s want %s", c.cur, c.free, got, c.want)
		}
	}
}

func TestTrafficRefresherBudgetAndDedupe(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Query().Get("key") != "secret" {
			t.Errorf("key not sent")
		}
		w.Write([]byte(tomtomBody))
	}))
	defer srv.Close()
	h := NewHub()
	tr := &Traffic{Hub: h, Key: "secret", BaseURL: srv.URL, DailyRequests: 10}
	p := geo.Point{Lat: 28.652, Lon: 77.242}

	tr.EnsureFresh(context.Background(), p, 5, 3*time.Second)
	if calls.Load() != 7 {
		t.Fatalf("calls = %d, want 7 samples", calls.Load())
	}
	// All 7 samples hit the same segment → one object.
	got := h.Find(Query{Center: &p, RadiusKm: 5, Kinds: []Kind{KindTraffic}})
	if len(got) != 1 || got[0].Status != "heavy" {
		t.Fatalf("traffic = %+v", got)
	}
	// Same area again within MaxAge: no new requests.
	tr.EnsureFresh(context.Background(), p, 5, 3*time.Second)
	if calls.Load() != 7 {
		t.Fatalf("refetched within MaxAge: %d", calls.Load())
	}
	// Another area: 7 more would exceed the budget of 10.
	tr.EnsureFresh(context.Background(), geo.Point{Lat: 19.07, Lon: 72.87}, 5, 3*time.Second)
	if calls.Load() != 7 {
		t.Fatalf("budget not enforced: %d", calls.Load())
	}
	if u := tr.Usage(); u["requests_today"] != 7 {
		t.Fatalf("usage = %v", u)
	}
}

func TestRefreshersOnlyRunWantedKinds(t *testing.T) {
	var flights, weather atomic.Int32
	rs := Refreshers{fakeRefresher{KindFlight, &flights}, fakeRefresher{KindWeather, &weather}}
	rs.Ensure(context.Background(), []Kind{KindWeather}, geo.Point{}, 1, time.Second)
	if flights.Load() != 0 || weather.Load() != 1 {
		t.Fatalf("flights=%d weather=%d", flights.Load(), weather.Load())
	}
	rs.Ensure(context.Background(), nil, geo.Point{}, 1, time.Second)
	if flights.Load() != 1 || weather.Load() != 2 {
		t.Fatal("empty kinds should run all")
	}
}

type fakeRefresher struct {
	k Kind
	n *atomic.Int32
}

func (f fakeRefresher) Kind() Kind { return f.k }
func (f fakeRefresher) EnsureFresh(context.Context, geo.Point, float64, time.Duration) {
	f.n.Add(1)
}
