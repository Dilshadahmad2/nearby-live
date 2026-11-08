// Package rail holds Indian Railways stations, trains and timetables, and
// estimates where a train is from its schedule.
package rail

import (
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// IST is Indian Standard Time (fixed +05:30, no DST), so the server needs no
// tzdata.
var IST = time.FixedZone("IST", 5*3600+30*60)

// Station is a railway station. Point is nil when the source has no
// coordinates for it.
type Station struct {
	Code    string     `json:"code"`
	Name    string     `json:"name"`
	State   string     `json:"state,omitempty"`
	Zone    string     `json:"zone,omitempty"`
	Address string     `json:"address,omitempty"`
	Point   *geo.Point `json:"location"`
}

// Train is a scheduled service.
type Train struct {
	Number      string `json:"number"`
	Name        string `json:"name"`
	Type        string `json:"type,omitempty"`
	Zone        string `json:"zone,omitempty"`
	FromCode    string `json:"from_code"`
	ToCode      string `json:"to_code"`
	Departure   string `json:"departure,omitempty"`
	Arrival     string `json:"arrival,omitempty"`
	DurationMin int    `json:"duration_min,omitempty"`
	DistanceKm  int    `json:"distance_km,omitempty"`
	ReturnTrain string `json:"return_train,omitempty"`
}

// Stop is one timetable row. ArrivalMin / DepartureMin are minutes from
// 00:00 IST of the day the train leaves its origin; nil when not published.
type Stop struct {
	Seq          int    `json:"seq"`
	StationCode  string `json:"station_code"`
	Day          int    `json:"day,omitempty"`
	ArrivalMin   *int   `json:"arrival_min,omitempty"`
	DepartureMin *int   `json:"departure_min,omitempty"`
}

// arr / dep with fallbacks to each other.
func (s Stop) arr() (int, bool) {
	if s.ArrivalMin != nil {
		return *s.ArrivalMin, true
	}
	if s.DepartureMin != nil {
		return *s.DepartureMin, true
	}
	return 0, false
}

func (s Stop) dep() (int, bool) {
	if s.DepartureMin != nil {
		return *s.DepartureMin, true
	}
	if s.ArrivalMin != nil {
		return *s.ArrivalMin, true
	}
	return 0, false
}

// IntPtr is a helper for tests and seeders.
func IntPtr(v int) *int { return &v }
