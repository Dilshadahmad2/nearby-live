package live

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/delay"
	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
	"github.com/dilshadahmad2/nearby-live/backend/internal/rail"
)

var t0 = time.Date(2026, 11, 7, 10, 30, 0, 0, rail.IST)

func TestHubFindRadiusAndBBox(t *testing.T) {
	h := NewHub()
	h.SetClock(func() time.Time { return t0 })
	h.Replace(KindTrain, "test", []Object{
		{ID: "a", Point: geo.Point{Lat: 28.65, Lon: 77.24}, FixTime: t0},
		{ID: "b", Point: geo.Point{Lat: 28.70, Lon: 77.24}, FixTime: t0}, // ~5.6 km
		{ID: "c", Point: geo.Point{Lat: 19.07, Lon: 72.87}, FixTime: t0}, // Mumbai
	})
	h.Replace(KindFlight, "test", []Object{{ID: "f", Point: geo.Point{Lat: 28.66, Lon: 77.25}, FixTime: t0}})

	c := geo.Point{Lat: 28.65, Lon: 77.24}
	got := h.Find(Query{Center: &c, RadiusKm: 10})
	if len(got) != 3 || got[0].ID != "a" || got[2].ID != "b" {
		t.Fatalf("radius: %+v", got)
	}
	got = h.Find(Query{Center: &c, RadiusKm: 10, Kinds: []Kind{KindTrain}})
	if len(got) != 2 {
		t.Fatalf("kind filter: %d", len(got))
	}
	got = h.Find(Query{BBox: &geo.BBox{South: 18, West: 72, North: 20, East: 73}})
	if len(got) != 1 || got[0].ID != "c" {
		t.Fatalf("bbox: %+v", got)
	}
}

func TestHubDeadReckonsFlights(t *testing.T) {
	h := NewHub()
	now := t0
	h.SetClock(func() time.Time { return now })
	h.Upsert(KindFlight, "test", []Object{{
		ID: "f", Point: geo.Point{Lat: 28, Lon: 77}, HeadingDeg: 0, SpeedKmh: 720, FixTime: t0, DeadReckon: true,
	}}, FlightExpire)
	now = t0.Add(time.Minute) // 720 km/h × 1 min = 12 km north
	o, _ := h.Get(KindFlight, "f")
	if d := geo.HaversineKm(geo.Point{Lat: 28, Lon: 77}, o.Point); d < 11.9 || d > 12.1 {
		t.Fatalf("moved %.2f km", d)
	}
	// Capped at MaxDeadReckon.
	now = t0.Add(time.Hour)
	o, _ = h.Get(KindFlight, "f")
	if d := geo.HaversineKm(geo.Point{Lat: 28, Lon: 77}, o.Point); d > 36.1 {
		t.Fatalf("moved %.2f km, cap is 3 min", d)
	}
	// Upsert expires objects not refreshed.
	h.Upsert(KindFlight, "test", []Object{{ID: "g", Point: geo.Point{Lat: 1, Lon: 1}, FixTime: now}}, FlightExpire)
	if _, ok := h.Get(KindFlight, "f"); ok {
		t.Fatal("stale flight should expire")
	}
}

func TestParseOpenSkyAndCredits(t *testing.T) {
	objs, err := ParseOpenSky([]byte(`{"time": 1762512000, "states": [
		["800c1b", "AIC138  ", "India", 1762511995, 1762511999, 77.21, 28.62, 3200.5, false, 180.2, 245.0, -5.2, null, 3350.0, "1234", false, 0],
		["800aaa", "IGO22   ", "India", null, 1762511999, null, null, null, false, null, null, null, null, null, null, false, 0]
	]}`))
	if err != nil || len(objs) != 1 {
		t.Fatalf("objs=%v err=%v", objs, err)
	}
	o := objs[0]
	if o.ID != "800c1b" || o.Label != "AIC138" || *o.AltitudeM != 3350 || o.SpeedKmh < 648 || o.SpeedKmh > 649 || !o.DeadReckon {
		t.Fatalf("flight = %+v", o)
	}
	if Credits(DefaultIndiaBBox) != 4 || Credits(geo.BBox{South: 28, West: 77, North: 29, East: 78}) != 1 {
		t.Fatal("credit cost")
	}
}

func TestOpenSkyFetchBudgetAnd429(t *testing.T) {
	var calls atomic.Int32
	var limited atomic.Bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if limited.Load() {
			w.Header().Set("X-Rate-Limit-Retry-After-Seconds", "120")
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		if !strings.HasPrefix(r.URL.Path, "/states/all") || r.URL.Query().Get("lamin") == "" {
			t.Errorf("bad request %s", r.URL)
		}
		ts := strconv.FormatInt(time.Now().Unix(), 10)
		w.Write([]byte(`{"time": ` + ts + `, "states": [["abc", "T1", "IN", ` + ts + `, ` + ts + `, 77.2, 28.6, 1000, false, 200, 90, 0, null, 1000, null, false, 0]]}`))
	}))
	defer srv.Close()
	h := NewHub()
	sky := &OpenSky{Hub: h, Coverage: DefaultIndiaBBox, BaseURL: srv.URL, DailyCredits: 5, SweepInterval: time.Hour}
	sky.init()

	if err := sky.fetch(context.Background(), DefaultIndiaBBox); err != nil { // 4 credits
		t.Fatal(err)
	}
	if len(h.Find(Query{BBox: &DefaultIndiaBBox})) != 1 {
		t.Fatal("flight not stored")
	}
	if err := sky.fetch(context.Background(), DefaultIndiaBBox); err != ErrNoCredits { // would exceed 5
		t.Fatalf("err = %v, want budget", err)
	}
	limited.Store(true)
	small := geo.BBox{South: 28, West: 77, North: 29, East: 78}
	if err := sky.fetch(context.Background(), small); err == nil {
		t.Fatal("429 should fail")
	}
	before := calls.Load()
	sky.mu.Lock()
	sky.used = 0
	sky.mu.Unlock()
	if err := sky.fetch(context.Background(), small); err != ErrNoCredits || calls.Load() != before {
		t.Fatal("should not call OpenSky while backing off")
	}
}

func testIndex() *rail.Index {
	stations := []rail.Station{
		{Code: "AAA", Name: "Alpha", Point: &geo.Point{Lat: 28, Lon: 77}},
		{Code: "CCC", Name: "Charlie", Point: &geo.Point{Lat: 29, Lon: 77}},
	}
	stops := map[string][]rail.Stop{"10001": {
		{Seq: 1, StationCode: "AAA", DepartureMin: rail.IntPtr(600)},
		{Seq: 2, StationCode: "CCC", ArrivalMin: rail.IntPtr(720)},
	}}
	return rail.NewIndex(stations, []rail.Train{{Number: "10001", Name: "Test Express", FromCode: "AAA", ToCode: "CCC"}}, stops)
}

func TestTrainSourceAppliesDelayAndLiveFix(t *testing.T) {
	ix := testIndex()
	d := delay.NewService(nil, nil, delay.Config{})
	d.SetClock(func() time.Time { return t0 })
	src := &TrainSource{Hub: NewHub(), Index: func() *rail.Index { return ix }, Delays: d, Now: func() time.Time { return t0 }}

	objs := src.Snapshot() // on time: 25 % of the way at 10:30
	if len(objs) != 1 || objs[0].Point.Lat < 28.24 || objs[0].Point.Lat > 28.26 || objs[0].DelayMin != nil {
		t.Fatalf("on time: %+v", objs)
	}

	_ = d.Put(context.Background(), delay.Status{TrainNumber: "10001", DelayMin: 30, Source: "push", ReportedAt: t0})
	objs = src.Snapshot() // 30 min late: just leaving AAA
	if len(objs) != 1 || *objs[0].DelayMin != 30 || objs[0].Point.Lat > 28.01 {
		t.Fatalf("late: %+v", objs)
	}

	fix := geo.Point{Lat: 28.4, Lon: 77.01}
	_ = d.Put(context.Background(), delay.Status{TrainNumber: "10001", DelayMin: 5, Point: &fix, Source: "gps", ReportedAt: t0})
	objs = src.Snapshot()
	if len(objs) != 1 || objs[0].Point != fix || objs[0].Source != "gps" {
		t.Fatalf("live fix: %+v", objs)
	}
}
