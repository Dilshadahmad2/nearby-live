package rail

import (
	"sort"
	"strings"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// Index is an immutable in-memory copy of the rail tables (about 20 MB for
// all of India), so lookups and nearby-train estimates need no DB round
// trips. The database stays the source of truth; the server rebuilds the
// index from it at start-up (and on reload).
type Index struct {
	stations        map[string]*Station
	located         []*Station // stations with coordinates, sorted by latitude
	trains          map[string]*Train
	stops           map[string][]Stop   // by train number, in seq order
	trainsAtStation map[string][]string // station code → train numbers
	LoadedAt        time.Time
}

// NewIndex builds an index from rows loaded from the database.
func NewIndex(stations []Station, trains []Train, stops map[string][]Stop) *Index {
	ix := &Index{
		stations:        make(map[string]*Station, len(stations)),
		trains:          make(map[string]*Train, len(trains)),
		stops:           make(map[string][]Stop, len(stops)),
		trainsAtStation: make(map[string][]string),
		LoadedAt:        time.Now(),
	}
	for i := range stations {
		s := &stations[i]
		ix.stations[s.Code] = s
		if s.Point != nil {
			ix.located = append(ix.located, s)
		}
	}
	sort.Slice(ix.located, func(i, j int) bool { return ix.located[i].Point.Lat < ix.located[j].Point.Lat })
	for i := range trains {
		ix.trains[trains[i].Number] = &trains[i]
	}
	for num, list := range stops {
		l := append([]Stop(nil), list...)
		sort.Slice(l, func(i, j int) bool { return l[i].Seq < l[j].Seq })
		ix.stops[num] = l
		seen := map[string]bool{}
		for _, s := range l {
			if !seen[s.StationCode] {
				seen[s.StationCode] = true
				ix.trainsAtStation[s.StationCode] = append(ix.trainsAtStation[s.StationCode], num)
			}
		}
	}
	return ix
}

// Counts for health output.
func (ix *Index) Counts() (stations, located, trains, stops int) {
	for _, l := range ix.stops {
		stops += len(l)
	}
	return len(ix.stations), len(ix.located), len(ix.trains), stops
}

// Station by code (case-insensitive), or nil.
func (ix *Index) Station(code string) *Station {
	return ix.stations[strings.ToUpper(strings.TrimSpace(code))]
}

// Train by number, or nil.
func (ix *Index) Train(number string) *Train { return ix.trains[strings.TrimSpace(number)] }

// Stops of a train in route order.
func (ix *Index) Stops(number string) []Stop { return ix.stops[strings.TrimSpace(number)] }

// NearbyStation is a station with its distance from a query point.
type NearbyStation struct {
	Station
	DistanceKm float64 `json:"distance_km"`
}

// NearbyStations returns located stations within radiusKm of p, nearest first.
func (ix *Index) NearbyStations(p geo.Point, radiusKm float64, limit int) []NearbyStation {
	box := geo.BoundingBox(p, radiusKm)
	lo := sort.Search(len(ix.located), func(i int) bool { return ix.located[i].Point.Lat >= box.South })
	var out []NearbyStation
	for i := lo; i < len(ix.located) && ix.located[i].Point.Lat <= box.North; i++ {
		s := ix.located[i]
		if !box.Contains(*s.Point) {
			continue
		}
		if d := geo.HaversineKm(p, *s.Point); d <= radiusKm {
			out = append(out, NearbyStation{Station: *s, DistanceKm: round3(d)})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].DistanceKm < out[j].DistanceKm })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}

// StationsInBBox returns located stations inside b.
func (ix *Index) StationsInBBox(b geo.BBox, limit int) []Station {
	lo := sort.Search(len(ix.located), func(i int) bool { return ix.located[i].Point.Lat >= b.South })
	var out []Station
	for i := lo; i < len(ix.located) && ix.located[i].Point.Lat <= b.North; i++ {
		if b.Contains(*ix.located[i].Point) {
			out = append(out, *ix.located[i])
			if limit > 0 && len(out) >= limit {
				break
			}
		}
	}
	return out
}

// SearchStations matches code exactly first, then name prefix, then name
// substring (case-insensitive).
func (ix *Index) SearchStations(q string, limit int) []Station {
	q = strings.ToLower(strings.TrimSpace(q))
	if q == "" {
		return nil
	}
	var exact, prefix, contains []Station
	for _, s := range ix.stations {
		name := strings.ToLower(s.Name)
		switch {
		case strings.ToLower(s.Code) == q:
			exact = append(exact, *s)
		case strings.HasPrefix(name, q):
			prefix = append(prefix, *s)
		case strings.Contains(name, q):
			contains = append(contains, *s)
		}
	}
	byName := func(l []Station) {
		sort.Slice(l, func(i, j int) bool { return l[i].Name < l[j].Name })
	}
	byName(prefix)
	byName(contains)
	out := append(append(exact, prefix...), contains...)
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}

// SearchTrains matches the number exactly or as a prefix, or the name.
func (ix *Index) SearchTrains(q string, limit int) []Train {
	q = strings.ToLower(strings.TrimSpace(q))
	if q == "" {
		return nil
	}
	var out []Train
	for _, t := range ix.trains {
		if strings.HasPrefix(t.Number, q) || strings.Contains(strings.ToLower(t.Name), q) {
			out = append(out, *t)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Number < out[j].Number })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}

// TrainsAtStation lists the train numbers that stop at or pass a station.
func (ix *Index) TrainsAtStation(code string) []string {
	return ix.trainsAtStation[strings.ToUpper(strings.TrimSpace(code))]
}

// StationLookup adapts the index for [Timeline].
func (ix *Index) StationLookup(code string) *Station { return ix.stations[code] }

// TrainPosition estimates where train number is at time at.
func (ix *Index) TrainPosition(number string, at time.Time, delay time.Duration) (Position, bool) {
	stops := ix.Stops(number)
	if len(stops) == 0 {
		return Position{}, false
	}
	_, p := FindJourney(stops, ix.StationLookup, at, delay)
	return p, true
}

// NearbyTrain is a train estimated to be near a query point.
type NearbyTrain struct {
	Train    Train    `json:"train"`
	Position Position `json:"position"`
	// DistanceKm from the query point to the estimated position.
	DistanceKm float64 `json:"distance_km"`
}

// NearbyTrains estimates every train whose route touches a station within
// radiusKm (+ 60 km for long non-stop runs) and keeps those whose
// estimated position is within radiusKm, nearest first.
func (ix *Index) NearbyTrains(p geo.Point, radiusKm float64, at time.Time, limit int) []NearbyTrain {
	const margin = 60.0
	cands := map[string]bool{}
	for _, s := range ix.NearbyStations(p, radiusKm+margin, 0) {
		for _, n := range ix.trainsAtStation[s.Code] {
			cands[n] = true
		}
	}
	var out []NearbyTrain
	for n := range cands {
		pos, ok := ix.TrainPosition(n, at, 0)
		if !ok || pos.Point == nil || (pos.Status != StatusRunning && pos.Status != StatusAtStation) {
			continue
		}
		d := geo.HaversineKm(p, *pos.Point)
		if d > radiusKm {
			continue
		}
		t := ix.trains[n]
		if t == nil {
			t = &Train{Number: n}
		}
		out = append(out, NearbyTrain{Train: *t, Position: pos, DistanceKm: round3(d)})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].DistanceKm < out[j].DistanceKm })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}

func round3(v float64) float64 { return float64(int64(v*1000+0.5)) / 1000 }
