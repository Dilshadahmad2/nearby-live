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

// KindEvent is an event at a venue (concert, match, festival).
const KindEvent Kind = "event"

// Events fetches upcoming events (next 24 h) around requests from the
// Ticketmaster Discovery API (free key), per ~11 km cell, cached for MaxAge.
type Events struct {
	Hub           *Hub
	Key           string
	BaseURL       string        // default https://app.ticketmaster.com/discovery/v2/events.json
	MaxAge        time.Duration // default 30 min
	DailyRequests int           // default 4000 (Ticketmaster free tier is 5,000/day)
	Client        *http.Client
	Log           *slog.Logger
	Now           func() time.Time

	gate   areaGate
	once   sync.Once
	budget dailyBudget
}

// Kind implements [Refresher].
func (e *Events) Kind() Kind { return KindEvent }

func (e *Events) init() {
	e.once.Do(func() {
		if e.BaseURL == "" {
			e.BaseURL = "https://app.ticketmaster.com/discovery/v2/events.json"
		}
		if e.MaxAge <= 0 {
			e.MaxAge = 30 * time.Minute
		}
		if e.DailyRequests <= 0 {
			e.DailyRequests = 4000
		}
		e.budget.limit = e.DailyRequests
		if e.Client == nil {
			e.Client = &http.Client{Timeout: 15 * time.Second}
		}
		if e.Now == nil {
			e.Now = time.Now
		}
	})
}

// EnsureFresh implements [Refresher].
func (e *Events) EnsureFresh(ctx context.Context, p geo.Point, radiusKm float64, wait time.Duration) {
	e.init()
	c := gridCell(p, WeatherCellDeg)
	e.gate.run(ctx, c, e.MaxAge, wait, func(ctx context.Context) {
		if err := e.fetch(ctx, p, radiusKm); err != nil {
			e.Hub.Fail(KindEvent, "ticketmaster", err)
			if e.Log != nil {
				e.Log.Debug("events", "err", err)
			}
		}
	})
}

func (e *Events) fetch(ctx context.Context, p geo.Point, radiusKm float64) error {
	if !e.budget.take(1) {
		return fmt.Errorf("ticketmaster: daily request budget used up")
	}
	now := e.Now().UTC()
	q := url.Values{
		"apikey":        {e.Key},
		"latlong":       {strconv.FormatFloat(p.Lat, 'f', 4, 64) + "," + strconv.FormatFloat(p.Lon, 'f', 4, 64)},
		"radius":        {strconv.Itoa(int(min(max(radiusKm, 10), 100)))},
		"unit":          {"km"},
		"size":          {"50"},
		"sort":          {"date,asc"},
		"startDateTime": {now.Format("2006-01-02T15:04:05Z")},
		"endDateTime":   {now.Add(24 * time.Hour).Format("2006-01-02T15:04:05Z")},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, e.BaseURL+"?"+q.Encode(), nil)
	if err != nil {
		return err
	}
	res, err := e.Client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode/100 != 2 {
		return fmt.Errorf("ticketmaster: HTTP %d", res.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, 8<<20))
	if err != nil {
		return err
	}
	objs, err := ParseTicketmaster(body, e.Now())
	if err != nil {
		return err
	}
	e.Hub.Upsert(KindEvent, "ticketmaster", objs, 6*time.Hour)
	return nil
}

// ParseTicketmaster converts a Discovery API events response. Events
// without venue coordinates are skipped.
func ParseTicketmaster(body []byte, now time.Time) ([]Object, error) {
	var doc struct {
		Embedded struct {
			Events []struct {
				ID    string `json:"id"`
				Name  string `json:"name"`
				URL   string `json:"url"`
				Dates struct {
					Start struct {
						LocalDate string `json:"localDate"`
						LocalTime string `json:"localTime"`
						DateTime  string `json:"dateTime"`
					} `json:"start"`
				} `json:"dates"`
				Classifications []struct {
					Segment struct {
						Name string `json:"name"`
					} `json:"segment"`
				} `json:"classifications"`
				Embedded struct {
					Venues []struct {
						Name     string `json:"name"`
						Location struct {
							Latitude  string `json:"latitude"`
							Longitude string `json:"longitude"`
						} `json:"location"`
					} `json:"venues"`
				} `json:"_embedded"`
			} `json:"events"`
		} `json:"_embedded"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("ticketmaster: %w", err)
	}
	var out []Object
	for _, ev := range doc.Embedded.Events {
		if len(ev.Embedded.Venues) == 0 {
			continue
		}
		v := ev.Embedded.Venues[0]
		lat, err1 := strconv.ParseFloat(v.Location.Latitude, 64)
		lon, err2 := strconv.ParseFloat(v.Location.Longitude, 64)
		if err1 != nil || err2 != nil {
			continue
		}
		segment := ""
		if len(ev.Classifications) > 0 {
			segment = ev.Classifications[0].Segment.Name
		}
		out = append(out, Object{
			ID:      "tm:" + ev.ID,
			Kind:    KindEvent,
			Point:   geo.Point{Lat: lat, Lon: lon},
			Label:   ev.Name,
			Name:    v.Name,
			Status:  "upcoming",
			Source:  "ticketmaster",
			FixTime: now,
			Extra: map[string]any{
				"start":      ev.Dates.Start.DateTime,
				"local_date": ev.Dates.Start.LocalDate,
				"local_time": ev.Dates.Start.LocalTime,
				"venue":      v.Name,
				"category":   segment,
				"url":        ev.URL,
			},
		})
	}
	return out, nil
}
