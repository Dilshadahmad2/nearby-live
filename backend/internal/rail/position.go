package rail

import (
	"math"
	"sort"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// Status of a train at a moment.
type Status string

const (
	StatusScheduled Status = "scheduled" // journey has not started
	StatusRunning   Status = "running"   // between two stops
	StatusAtStation Status = "at_station"
	StatusArrived   Status = "arrived" // reached its destination
	StatusUnknown   Status = "unknown" // timetable or coordinates missing
)

// StopRef identifies a stop in a position answer.
type StopRef struct {
	Seq       int        `json:"seq"`
	Code      string     `json:"code"`
	Name      string     `json:"name,omitempty"`
	Point     *geo.Point `json:"location,omitempty"`
	Arrival   *time.Time `json:"arrival,omitempty"`
	Departure *time.Time `json:"departure,omitempty"`
}

// Position is an estimated train position.
type Position struct {
	Status       Status     `json:"status"`
	Point        *geo.Point `json:"location,omitempty"`
	BearingDeg   float64    `json:"bearing_deg"`
	SpeedKmh     float64    `json:"speed_kmh"`
	Progress     float64    `json:"segment_progress"` // 0..1 between Prev and Next
	Prev         *StopRef   `json:"prev_stop,omitempty"`
	Next         *StopRef   `json:"next_stop,omitempty"`
	JourneyStart time.Time  `json:"journey_start_date"`
	At           time.Time  `json:"at"`
	DelayMin     int        `json:"delay_min"`
	Estimated    bool       `json:"estimated"`
}

// TimedStop is a stop with absolute times and (optionally) a location. It is
// the input of [EstimateAt]; build it from the timetable with [Timeline] or
// directly from a live provider's last/next station data.
type TimedStop struct {
	Seq       int
	Code      string
	Name      string
	Point     *geo.Point
	Arrival   time.Time
	Departure time.Time
}

// Timeline converts timetable stops into absolute times for a journey that
// starts on startDate (any time on that IST day). Stops without any time are
// dropped, and so are rows whose times go backwards (bad source rows).
func Timeline(stops []Stop, stations func(code string) *Station, startDate time.Time) []TimedStop {
	y, m, d := startDate.In(IST).Date()
	midnight := time.Date(y, m, d, 0, 0, 0, 0, IST)
	sorted := append([]Stop(nil), stops...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Seq < sorted[j].Seq })
	out := make([]TimedStop, 0, len(sorted))
	last := math.MinInt
	for _, s := range sorted {
		a, okA := s.arr()
		dp, okD := s.dep()
		if !okA || !okD {
			continue
		}
		if dp < a {
			dp = a
		}
		if a < last {
			continue
		}
		last = dp
		ts := TimedStop{
			Seq:       s.Seq,
			Code:      s.StationCode,
			Arrival:   midnight.Add(time.Duration(a) * time.Minute),
			Departure: midnight.Add(time.Duration(dp) * time.Minute),
		}
		if st := stations(s.StationCode); st != nil {
			ts.Name = st.Name
			ts.Point = st.Point
		}
		out = append(out, ts)
	}
	return out
}

// EstimateAt estimates where a train following tl is at time at, with an
// optional delay applied to every stop. The position is interpolated along
// the great circle between the nearest located stops before and after at,
// by time. Stops with no coordinates are bridged.
func EstimateAt(tl []TimedStop, at time.Time, delay time.Duration) Position {
	p := Position{At: at, DelayMin: int(delay / time.Minute), Estimated: true}
	if len(tl) < 2 {
		p.Status = StatusUnknown
		return p
	}
	p.JourneyStart = startDay(tl[0].Departure)
	t := at.Add(-delay) // compare against the published timetable

	first, last := tl[0], tl[len(tl)-1]
	switch {
	case t.Before(first.Departure):
		p.Status = StatusScheduled
		p.Point = first.Point
		p.Next = ref(first, delay)
		return p
	case !t.Before(last.Arrival):
		p.Status = StatusArrived
		p.Point = last.Point
		p.Prev = ref(last, delay)
		return p
	}

	// Find the segment: either dwelling at stop i, or between i and i+1.
	i := sort.Search(len(tl), func(k int) bool { return tl[k].Arrival.After(t) }) - 1
	if i < 0 {
		i = 0
	}
	cur := tl[i]
	if !t.After(cur.Departure) && !t.Before(cur.Arrival) && cur.Departure.After(cur.Arrival) {
		p.Status = StatusAtStation
		p.Prev = ref(cur, delay)
		if i+1 < len(tl) {
			p.Next = ref(tl[i+1], delay)
		}
		if cur.Point != nil {
			p.Point = cur.Point
			if p.Next != nil && p.Next.Point != nil {
				p.BearingDeg = geo.BearingDeg(*cur.Point, *p.Next.Point)
			}
			return p
		}
		// Located nowhere: fall through to interpolation between neighbours.
	} else {
		p.Status = StatusRunning
		p.Prev = ref(cur, delay)
		if i+1 < len(tl) {
			p.Next = ref(tl[i+1], delay)
		}
	}
	if i+1 < len(tl) {
		seg := tl[i+1].Arrival.Sub(cur.Departure)
		if seg > 0 {
			p.Progress = clamp01(float64(t.Sub(cur.Departure)) / float64(seg))
		}
	}

	// Bracket by the nearest stops that have coordinates.
	a := -1
	for k := i; k >= 0; k-- {
		if tl[k].Point != nil {
			a = k
			break
		}
	}
	b := -1
	for k := i + 1; k < len(tl); k++ {
		if tl[k].Point != nil {
			b = k
			break
		}
	}
	if a < 0 || b < 0 {
		if p.Status == StatusAtStation || p.Status == StatusRunning {
			p.Status = StatusUnknown
		}
		return p
	}
	pa, pb := *tl[a].Point, *tl[b].Point
	span := tl[b].Arrival.Sub(tl[a].Departure)
	f := 0.0
	if span > 0 {
		f = clamp01(float64(t.Sub(tl[a].Departure)) / float64(span))
	}
	pt := geo.Interpolate(pa, pb, f)
	p.Point = &pt
	p.BearingDeg = geo.BearingDeg(pa, pb)
	if span > 0 {
		p.SpeedKmh = geo.HaversineKm(pa, pb) / span.Hours()
	}
	if p.Status == StatusAtStation {
		p.SpeedKmh = 0
	}
	return p
}

// FindJourney picks the journey that is running at time at: the train may
// have left its origin today or up to a few days ago. It returns the
// timeline and position of the most recent journey that is running (or at a
// station). When none is, it returns the next scheduled journey. Running
// days are not in the source data, so the train is assumed to run daily.
func FindJourney(stops []Stop, stations func(string) *Station, at time.Time, delay time.Duration) ([]TimedStop, Position) {
	maxDays := 1
	for _, s := range stops {
		if v, ok := s.arr(); ok && v/1440+1 > maxDays {
			maxDays = v/1440 + 1
		}
	}
	if maxDays > 7 {
		maxDays = 7
	}
	today := at.In(IST)
	for k := 0; k <= maxDays; k++ {
		tl := Timeline(stops, stations, today.AddDate(0, 0, -k))
		p := EstimateAt(tl, at, delay)
		if p.Status == StatusRunning || p.Status == StatusAtStation {
			return tl, p
		}
	}
	tl := Timeline(stops, stations, today)
	p := EstimateAt(tl, at, delay)
	if p.Status == StatusArrived {
		tl = Timeline(stops, stations, today.AddDate(0, 0, 1))
		p = EstimateAt(tl, at, delay)
	}
	return tl, p
}

func ref(s TimedStop, delay time.Duration) *StopRef {
	a := s.Arrival.Add(delay)
	d := s.Departure.Add(delay)
	return &StopRef{Seq: s.Seq, Code: s.Code, Name: s.Name, Point: s.Point, Arrival: &a, Departure: &d}
}

func startDay(t time.Time) time.Time {
	y, m, d := t.In(IST).Date()
	return time.Date(y, m, d, 0, 0, 0, 0, IST)
}

func clamp01(v float64) float64 { return math.Max(0, math.Min(1, v)) }
