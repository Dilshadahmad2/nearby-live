package rail

import (
	"math"
	"testing"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

func pt(lat, lon float64) *geo.Point { return &geo.Point{Lat: lat, Lon: lon} }

// A → B (no coordinates) → C, 0:00–2:00 with a 10-minute halt at B.
func testIndex() *Index {
	stations := []Station{
		{Code: "AAA", Name: "Alpha", Point: pt(28.0, 77.0)},
		{Code: "BBB", Name: "Bravo"}, // missing location
		{Code: "CCC", Name: "Charlie", Point: pt(29.0, 77.0)},
	}
	stops := map[string][]Stop{
		"10001": {
			{Seq: 1, StationCode: "AAA", DepartureMin: IntPtr(600)},                          // 10:00
			{Seq: 2, StationCode: "BBB", ArrivalMin: IntPtr(650), DepartureMin: IntPtr(660)}, // 10:50–11:00
			{Seq: 3, StationCode: "CCC", ArrivalMin: IntPtr(720)},                            // 12:00
		},
	}
	return NewIndex(stations, []Train{{Number: "10001", Name: "Test Express", FromCode: "AAA", ToCode: "CCC"}}, stops)
}

func ist(h, m int) time.Time { return time.Date(2026, 11, 7, h, m, 0, 0, IST) }

func TestEstimateBridgesStationsWithoutLocation(t *testing.T) {
	ix := testIndex()
	tl := Timeline(ix.Stops("10001"), ix.StationLookup, ist(0, 0))

	p := EstimateAt(tl, ist(11, 0).Add(-30*time.Minute), 0) // 10:30
	if p.Status != StatusRunning {
		t.Fatalf("status = %s, want running", p.Status)
	}
	// AAA dep 10:00 → CCC arr 12:00 is the located span; 10:30 = 25 %.
	want := geo.Interpolate(*pt(28, 77), *pt(29, 77), .25)
	if d := geo.HaversineKm(*p.Point, want); d > .01 {
		t.Fatalf("position off by %.3f km", d)
	}
	if p.Prev.Code != "AAA" || p.Next.Code != "BBB" {
		t.Fatalf("prev/next = %s/%s", p.Prev.Code, p.Next.Code)
	}
	if math.Abs(p.Progress-0.6) > 1e-9 { // 30 of the 50 minutes to BBB
		t.Fatalf("progress = %v", p.Progress)
	}
	if math.Abs(p.BearingDeg) > .01 {
		t.Fatalf("bearing = %v, want north", p.BearingDeg)
	}
	// 111 km in 2 h.
	if math.Abs(p.SpeedKmh-55.6) > .5 {
		t.Fatalf("speed = %v", p.SpeedKmh)
	}
}

func TestEstimateStatuses(t *testing.T) {
	ix := testIndex()
	tl := Timeline(ix.Stops("10001"), ix.StationLookup, ist(0, 0))
	cases := []struct {
		at   time.Time
		want Status
	}{
		{ist(9, 0), StatusScheduled},
		{ist(10, 55), StatusAtStation}, // at BBB (bridged position)
		{ist(11, 30), StatusRunning},
		{ist(12, 0), StatusArrived},
	}
	for _, c := range cases {
		p := EstimateAt(tl, c.at, 0)
		if p.Status != c.want {
			t.Errorf("%s: status %s, want %s", c.at.Format("15:04"), p.Status, c.want)
		}
		if p.Point == nil {
			t.Errorf("%s: no position", c.at.Format("15:04"))
		}
	}
}

func TestDelayShiftsTheTimetable(t *testing.T) {
	ix := testIndex()
	tl := Timeline(ix.Stops("10001"), ix.StationLookup, ist(0, 0))
	onTime := EstimateAt(tl, ist(10, 30), 0)
	late := EstimateAt(tl, ist(11, 0), 30*time.Minute)
	if geo.HaversineKm(*onTime.Point, *late.Point) > .001 {
		t.Fatal("30 min late at 11:00 should be where an on-time train is at 10:30")
	}
	if late.Next.Arrival.Sub(*onTime.Next.Arrival) != 30*time.Minute {
		t.Fatal("next-stop ETA should include the delay")
	}
}

func TestFindJourneyAcrossMidnight(t *testing.T) {
	stations := []Station{{Code: "X", Point: pt(19, 72.8)}, {Code: "Y", Point: pt(28.6, 77.2)}}
	stops := []Stop{
		{Seq: 1, StationCode: "X", DepartureMin: IntPtr(1000)}, // 16:40 day 1
		{Seq: 2, StationCode: "Y", ArrivalMin: IntPtr(1950)},   // 08:30 day 2
	}
	ix := NewIndex(stations, nil, map[string][]Stop{"1": stops})
	look := ix.StationLookup

	// 02:00 on 8 Nov: the train that left on 7 Nov is running.
	_, p := FindJourney(stops, look, time.Date(2026, 11, 8, 2, 0, 0, 0, IST), 0)
	if p.Status != StatusRunning {
		t.Fatalf("status = %s", p.Status)
	}
	if got := p.JourneyStart.Format("2006-01-02"); got != "2026-11-07" {
		t.Fatalf("journey start = %s", got)
	}

	// 10:00 on 8 Nov: yesterday's arrived, today's not left yet.
	_, p = FindJourney(stops, look, time.Date(2026, 11, 8, 10, 0, 0, 0, IST), 0)
	if p.Status != StatusScheduled || p.Next == nil || p.Next.Departure.Format("2006-01-02 15:04") != "2026-11-08 16:40" {
		t.Fatalf("got %s next=%v", p.Status, p.Next)
	}
}

func TestTimelineDropsBackwardRows(t *testing.T) {
	stops := []Stop{
		{Seq: 1, StationCode: "A", DepartureMin: IntPtr(100)},
		{Seq: 2, StationCode: "B", ArrivalMin: IntPtr(50)}, // bad row
		{Seq: 3, StationCode: "C"},                         // no time
		{Seq: 4, StationCode: "D", ArrivalMin: IntPtr(200)},
	}
	tl := Timeline(stops, func(string) *Station { return nil }, ist(0, 0))
	if len(tl) != 2 || tl[0].Code != "A" || tl[1].Code != "D" {
		t.Fatalf("timeline = %+v", tl)
	}
}

func TestNearbyStationsAndSearch(t *testing.T) {
	ix := testIndex()
	got := ix.NearbyStations(geo.Point{Lat: 28.01, Lon: 77}, 5, 10)
	if len(got) != 1 || got[0].Code != "AAA" {
		t.Fatalf("nearby = %+v", got)
	}
	if s := ix.SearchStations("bra", 5); len(s) != 1 || s[0].Code != "BBB" {
		t.Fatalf("search = %+v", s)
	}
	if s := ix.SearchStations("ccc", 5); len(s) != 1 || s[0].Code != "CCC" {
		t.Fatalf("code search = %+v", s)
	}
}

func TestNearbyTrains(t *testing.T) {
	ix := testIndex()
	// 10:30 the train is ~28 km north of AAA.
	at := ist(10, 30)
	got := ix.NearbyTrains(geo.Point{Lat: 28.25, Lon: 77}, 5, at, 10, nil)
	if len(got) != 1 || got[0].Train.Number != "10001" {
		t.Fatalf("nearby trains = %+v", got)
	}
	if len(ix.NearbyTrains(geo.Point{Lat: 28.9, Lon: 77}, 5, at, 10, nil)) != 0 {
		t.Fatal("train should not be near CCC at 10:30")
	}
}

func TestNearbyTrainsAppliesDelay(t *testing.T) {
	ix := testIndex()
	at := ist(10, 30)
	// 30 minutes late: at 10:30 it is still at AAA, not 28 km north.
	late := func(string) time.Duration { return 30 * time.Minute }
	if got := ix.NearbyTrains(geo.Point{Lat: 28.25, Lon: 77}, 5, at, 10, late); len(got) != 0 {
		t.Fatalf("late train should not be near 28.25: %+v", got)
	}
	if got := ix.NearbyTrains(geo.Point{Lat: 28.0, Lon: 77}, 3, at.Add(time.Minute), 10, late); len(got) != 1 || got[0].Position.DelayMin != 30 {
		t.Fatalf("late train near AAA: %+v", got)
	}
}
