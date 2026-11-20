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
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// KindWeather is current weather for an area (one object per ~11 km cell).
const KindWeather Kind = "weather"

// Weather fetches current conditions from Open-Meteo (free, no key) for the
// cell around each request, cached for MaxAge. All users in a cell share
// one upstream request.
type Weather struct {
	Hub     *Hub
	BaseURL string        // default https://api.open-meteo.com/v1/forecast
	MaxAge  time.Duration // default 10 min
	Client  *http.Client
	Log     *slog.Logger

	gate areaGate
}

// WeatherCellDeg is the cache cell size (0.1° ≈ 11 km).
const WeatherCellDeg = 0.1

// Kind implements [Refresher].
func (w *Weather) Kind() Kind { return KindWeather }

// EnsureFresh implements [Refresher].
func (w *Weather) EnsureFresh(ctx context.Context, p geo.Point, _ float64, wait time.Duration) {
	maxAge := w.MaxAge
	if maxAge <= 0 {
		maxAge = 10 * time.Minute
	}
	c := gridCell(p, WeatherCellDeg)
	w.gate.run(ctx, c, maxAge, wait, func(ctx context.Context) {
		if err := w.fetch(ctx, c); err != nil {
			w.Hub.Fail(KindWeather, "open-meteo", err)
			if w.Log != nil {
				w.Log.Debug("weather", "err", err)
			}
		}
	})
}

func (w *Weather) fetch(ctx context.Context, c cell) error {
	center := geo.Point{Lat: (float64(c.y) + .5) * WeatherCellDeg, Lon: (float64(c.x) + .5) * WeatherCellDeg}
	base := w.BaseURL
	if base == "" {
		base = "https://api.open-meteo.com/v1/forecast"
	}
	q := url.Values{
		"latitude":        {strconv.FormatFloat(center.Lat, 'f', 4, 64)},
		"longitude":       {strconv.FormatFloat(center.Lon, 'f', 4, 64)},
		"current":         {"temperature_2m,relative_humidity_2m,wind_speed_10m,precipitation_probability,weather_code"},
		"wind_speed_unit": {"kmh"},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"?"+q.Encode(), nil)
	if err != nil {
		return err
	}
	client := w.Client
	if client == nil {
		client = &http.Client{Timeout: 15 * time.Second}
	}
	res, err := client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode/100 != 2 {
		return fmt.Errorf("open-meteo: HTTP %d", res.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return err
	}
	o, err := ParseOpenMeteo(body)
	if err != nil {
		return err
	}
	o.ID = fmt.Sprintf("wx:%d:%d", c.x, c.y)
	o.Point = center
	w.Hub.Upsert(KindWeather, "open-meteo", []Object{o}, 45*time.Minute)
	return nil
}

// ParseOpenMeteo turns the `current` block into a weather object (ID and
// location are set by the caller).
func ParseOpenMeteo(body []byte) (Object, error) {
	var doc struct {
		Current map[string]any `json:"current"`
	}
	if err := json.Unmarshal(body, &doc); err != nil || doc.Current == nil {
		return Object{}, fmt.Errorf("open-meteo: missing current block")
	}
	f := func(k string) float64 { v, _ := doc.Current[k].(float64); return v }
	code := int(f("weather_code"))
	return Object{
		Kind:    KindWeather,
		Label:   WeatherLabel(code),
		Status:  WeatherLabel(code),
		Source:  "open-meteo",
		FixTime: time.Now(),
		Extra: map[string]any{
			"temperature_c": f("temperature_2m"),
			"humidity_pct":  int(f("relative_humidity_2m") + .5),
			"wind_kmh":      f("wind_speed_10m"),
			"rain_pct":      int(f("precipitation_probability") + .5),
			"code":          code,
		},
	}, nil
}

// WeatherLabel maps a WMO weather code to text.
func WeatherLabel(code int) string {
	switch {
	case code == 0:
		return "Clear Sky"
	case code == 1:
		return "Mainly Clear"
	case code == 2:
		return "Partly Cloudy"
	case code == 3:
		return "Overcast"
	case code == 45 || code == 48:
		return "Fog"
	case code >= 51 && code <= 57:
		return "Drizzle"
	case code >= 61 && code <= 67:
		return "Rain"
	case code >= 71 && code <= 77:
		return "Snow"
	case code >= 80 && code <= 82:
		return "Rain Showers"
	case code == 85 || code == 86:
		return "Snow Showers"
	case code >= 95:
		return "Thunderstorm"
	}
	return "Unknown"
}
