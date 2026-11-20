package rail

import (
	"sync"
	"testing"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

var (
	realOnce sync.Once
	realIx   *Index
	realErr  error
)

// realIndex loads the bundled CSVs (all of India).
func realIndex(t *testing.T) *Index {
	t.Helper()
	realOnce.Do(func() { realIx, realErr = LoadIndexFromCSV("../../data") })
	if realErr != nil {
		t.Fatalf("load CSVs: %v", realErr)
	}
	return realIx
}

func TestRealDataCounts(t *testing.T) {
	st, loc, tr, stops := realIndex(t).Counts()
	if st < 8900 || loc < 8600 || tr < 5000 || stops < 400000 {
		t.Fatalf("counts: stations=%d located=%d trains=%d stops=%d", st, loc, tr, stops)
	}
	ndls := realIndex(t).Station("ndls")
	if ndls == nil || ndls.Point == nil {
		t.Fatal("New Delhi (NDLS) missing or without location")
	}
	if d := geo.HaversineKm(*ndls.Point, geo.Point{Lat: 28.6431, Lon: 77.2197}); d > 2 {
		t.Fatalf("NDLS is %.1f km from its real position", d)
	}
}

// 12951 Mumbai Central → New Delhi Rajdhani: dep 16:40, arr 08:30 next day.
func TestRealRajdhaniPosition(t *testing.T) {
	ix := realIndex(t)
	if ix.Train("12951") == nil {
		t.Skip("12951 not in dataset")
	}
	at := time.Date(2026, 11, 7, 23, 0, 0, 0, IST)
	p, ok := ix.TrainPosition("12951", at, 0)
	if !ok || p.Point == nil {
		t.Fatalf("no position: %+v", p)
	}
	if p.Status != StatusRunning && p.Status != StatusAtStation {
		t.Fatalf("status = %s", p.Status)
	}
	// Somewhere between Mumbai and Delhi, well inside India.
	bct := ix.Station("BCT").Point
	ndls := ix.Station("NDLS").Point
	total := geo.HaversineKm(*bct, *ndls)
	if geo.HaversineKm(*bct, *p.Point) > total || geo.HaversineKm(*ndls, *p.Point) > total {
		t.Fatalf("position %v is not between BCT and NDLS", p.Point)
	}
	if p.SpeedKmh < 20 || p.SpeedKmh > 200 {
		t.Fatalf("implausible speed %.0f km/h", p.SpeedKmh)
	}

	// After arrival and before the next departure → scheduled for 16:40 today.
	p, _ = ix.TrainPosition("12951", time.Date(2026, 11, 8, 10, 0, 0, 0, IST), 0)
	if p.Status != StatusScheduled {
		t.Fatalf("10:00 status = %s", p.Status)
	}
}

func TestRealNearbyStationsAroundRedFort(t *testing.T) {
	got := realIndex(t).NearbyStations(geo.Point{Lat: 28.6540, Lon: 77.2410}, 3, 20)
	found := map[string]bool{}
	for _, s := range got {
		found[s.Code] = true
	}
	if !found["DLI"] { // Old Delhi Jn is ~1.5 km from Red Fort
		t.Fatalf("Old Delhi (DLI) not within 3 km: %+v", got)
	}
}
