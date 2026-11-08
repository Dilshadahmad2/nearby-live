package live

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// KindTraffic is a road segment with measured flow.
const KindTraffic Kind = "traffic"

// Traffic samples TomTom Flow Segment Data around requests. The API key
// stays on the server; all users in an area share the samples. Each
// refresh costs up to 7 TomTom requests (centre + ring), counted against
// DailyRequests.
type Traffic struct {
	Hub           *Hub
	Key           string
	BaseURL       string        // default TomTom flowSegmentData endpoint
	MaxAge        time.Duration // default 3 min per area
	DailyRequests int           // default 2000 (TomTom free tier is ~2,500/day)
	Client        *http.Client
	Log           *slog.Logger

	gate   areaGate
	once   sync.Once
	budget dailyBudget
}

// TrafficCellDeg is the area cell size (0.05° ≈ 5.5 km).
const TrafficCellDeg = 0.05

// Kind implements [Refresher].
func (t *Traffic) Kind() Kind { return KindTraffic }

func (t *Traffic) init() {
	t.once.Do(func() {
		if t.DailyRequests <= 0 {
			t.DailyRequests = 2000
		}
		t.budget.limit = t.DailyRequests
		if t.BaseURL == "" {
			t.BaseURL = "https://api.tomtom.com/traffic/services/4/flowSegmentData/absolute/10/json"
		}
		if t.MaxAge <= 0 {
			t.MaxAge = 3 * time.Minute
		}
		if t.Client == nil {
			t.Client = &http.Client{Timeout: 15 * time.Second}
		}
	})
}

// Usage reports today's TomTom requests.
func (t *Traffic) Usage() map[string]any {
	t.init()
	used, limit := t.budget.usage()
	return map[string]any{"requests_today": used, "daily_requests": limit}
}

// EnsureFresh implements [Refresher].
func (t *Traffic) EnsureFresh(ctx context.Context, p geo.Point, radiusKm float64, wait time.Duration) {
	t.init()
	c := gridCell(p, TrafficCellDeg)
	t.gate.run(ctx, c, t.MaxAge, wait, func(ctx context.Context) {
		if err := t.refresh(ctx, p, radiusKm); err != nil {
			t.Hub.Fail(KindTraffic, "tomtom", err)
			if t.Log != nil {
				t.Log.Debug("traffic", "err", err)
			}
		}
	})
}

// TrafficSamples: centre plus 6 points at 50 % of the range (capped at 8 km).
func TrafficSamples(c geo.Point, radiusKm float64) []geo.Point {
	r := min(radiusKm, 8) * .5
	out := []geo.Point{c}
	for i := 0; i < 6; i++ {
		out = append(out, destination(c, float64(i)*60, r))
	}
	return out
}

func (t *Traffic) refresh(ctx context.Context, p geo.Point, radiusKm float64) error {
	samples := TrafficSamples(p, radiusKm)
	if !t.budget.take(len(samples)) {
		return fmt.Errorf("tomtom: daily request budget used up")
	}
	type res struct {
		o   *Object
		err error
	}
	ch := make(chan res, len(samples))
	for _, s := range samples {
		go func(s geo.Point) {
			o, err := t.sample(ctx, s)
			ch <- res{o, err}
		}(s)
	}
	var objs []Object
	var lastErr error
	seen := map[string]bool{}
	for range samples {
		r := <-ch
		if r.err != nil {
			lastErr = r.err
			continue
		}
		if r.o != nil && !seen[r.o.ID] {
			seen[r.o.ID] = true
			objs = append(objs, *r.o)
		}
	}
	if len(objs) == 0 && lastErr != nil {
		return lastErr
	}
	t.Hub.Upsert(KindTraffic, "tomtom", objs, 10*time.Minute)
	return nil
}

func (t *Traffic) sample(ctx context.Context, p geo.Point) (*Object, error) {
	q := url.Values{
		"point": {strconv.FormatFloat(p.Lat, 'f', 5, 64) + "," + strconv.FormatFloat(p.Lon, 'f', 5, 64)},
		"unit":  {"KMPH"},
		"key":   {t.Key},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, t.BaseURL+"?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	resp, err := t.Client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("tomtom: HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	return ParseTomTomFlow(body)
}

// Congestion from currentSpeed / freeFlowSpeed (same thresholds as the app).
func Congestion(current, free float64, closed bool) string {
	switch {
	case closed:
		return "closed"
	case free <= 0:
		return "free"
	}
	r := current / free
	switch {
	case r >= .85:
		return "free"
	case r >= .65:
		return "light"
	case r >= .4:
		return "moderate"
	}
	return "heavy"
}

var frcLabels = map[string]string{
	"FRC0": "Motorway", "FRC1": "Major Road", "FRC2": "Main Road", "FRC3": "Secondary Road",
	"FRC4": "Connecting Road", "FRC5": "Local Road", "FRC6": "Local Road",
}

// ParseTomTomFlow converts one flowSegmentData response into a traffic
// object located at the segment's middle vertex (nil when no geometry).
func ParseTomTomFlow(body []byte) (*Object, error) {
	var doc struct {
		F *struct {
			FRC           string  `json:"frc"`
			CurrentSpeed  float64 `json:"currentSpeed"`
			FreeFlowSpeed float64 `json:"freeFlowSpeed"`
			RoadClosure   bool    `json:"roadClosure"`
			Coordinates   struct {
				Coordinate []struct {
					Lat float64 `json:"latitude"`
					Lon float64 `json:"longitude"`
				} `json:"coordinate"`
			} `json:"coordinates"`
		} `json:"flowSegmentData"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("tomtom: %w", err)
	}
	if doc.F == nil || len(doc.F.Coordinates.Coordinate) < 2 {
		return nil, nil
	}
	pts := doc.F.Coordinates.Coordinate
	coords := make([][2]float64, len(pts))
	for i, c := range pts {
		coords[i] = [2]float64{c.Lon, c.Lat}
	}
	first, last, mid := pts[0], pts[len(pts)-1], pts[len(pts)/2]
	cong := Congestion(doc.F.CurrentSpeed, doc.F.FreeFlowSpeed, doc.F.RoadClosure)
	return &Object{
		ID:       fmt.Sprintf("%.5f,%.5f-%.5f,%.5f", first.Lat, first.Lon, last.Lat, last.Lon),
		Kind:     KindTraffic,
		Point:    geo.Point{Lat: mid.Lat, Lon: mid.Lon},
		SpeedKmh: doc.F.CurrentSpeed,
		Label:    frcLabels[doc.F.FRC],
		Status:   cong,
		Source:   "tomtom",
		FixTime:  time.Now(),
		Extra: map[string]any{
			"current_kmh":   doc.F.CurrentSpeed,
			"free_flow_kmh": doc.F.FreeFlowSpeed,
			"closed":        doc.F.RoadClosure,
			"coordinates":   coords,
		},
	}, nil
}
