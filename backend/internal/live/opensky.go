package live

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// OpenSky polls the OpenSky Network `/states/all` endpoint and keeps the
// flight layer of the hub fresh.
//
// Two mechanisms share one daily credit budget:
//   - a background sweep of the whole coverage box (India by default) every
//     SweepInterval;
//   - on-demand refreshes of the area around a request ([OpenSky.EnsureFresh])
//     when that area is older than RegionMaxAge. Small boxes cost fewer
//     credits, so requests near users stay fresh even on a small budget.
//
// OpenSky charges credits per request by box area (≤25 sq° = 1, ≤100 = 2,
// ≤400 = 3, more = 4) and rate-limits with HTTP 429 plus
// X-Rate-Limit-Retry-After-Seconds. Anonymous access has the smallest daily
// allowance; set ClientID/ClientSecret (OAuth2 client credentials of an
// OpenSky account) for more.
type OpenSky struct {
	Hub           *Hub
	Coverage      geo.BBox
	SweepInterval time.Duration
	RegionMaxAge  time.Duration
	DailyCredits  int
	ClientID      string
	ClientSecret  string
	BaseURL       string // default https://opensky-network.org/api
	TokenURL      string // default OpenSky Keycloak token endpoint
	Client        *http.Client
	Log           *slog.Logger

	once        sync.Once
	mu          sync.Mutex
	token       string
	tokenExp    time.Time
	day         string
	used        int
	blockedTill time.Time
	regions     map[cell]time.Time // 1° cells → last refresh
	inflight    map[cell]chan struct{}
}

// DefaultIndiaBBox covers India and its approaches.
var DefaultIndiaBBox = geo.BBox{South: 6, West: 68, North: 37.5, East: 97.5}

// FlightExpire drops aircraft not seen for this long.
const FlightExpire = 5 * time.Minute

const defaultTokenURL = "https://auth.opensky-network.org/auth/realms/opensky-network/protocol/openid-connect/token"

// ErrNoCredits is returned when the daily budget is spent or OpenSky asked
// us to back off.
var ErrNoCredits = errors.New("opensky: credit budget exhausted or rate limited")

func (o *OpenSky) init() { o.once.Do(o.setDefaults) }

func (o *OpenSky) setDefaults() {
	if o.BaseURL == "" {
		o.BaseURL = "https://opensky-network.org/api"
	}
	if o.TokenURL == "" {
		o.TokenURL = defaultTokenURL
	}
	if o.Client == nil {
		o.Client = &http.Client{Timeout: 25 * time.Second}
	}
	if o.RegionMaxAge <= 0 {
		o.RegionMaxAge = 30 * time.Second
	}
	if o.DailyCredits <= 0 {
		if o.ClientID != "" {
			o.DailyCredits = 4000
		} else {
			o.DailyCredits = 400
		}
	}
	if o.SweepInterval <= 0 {
		// Spend about half the budget on sweeps, keep the rest for regions.
		cost := Credits(o.Coverage)
		perDay := float64(o.DailyCredits) / 2 / float64(cost)
		o.SweepInterval = time.Duration(float64(24*time.Hour) / math.Max(1, perDay))
		if o.SweepInterval < 30*time.Second {
			o.SweepInterval = 30 * time.Second
		}
	}
	if o.regions == nil {
		o.regions = map[cell]time.Time{}
		o.inflight = map[cell]chan struct{}{}
	}
}

// Credits OpenSky charges for a /states/all request over b.
func Credits(b geo.BBox) int {
	area := (b.North - b.South) * (b.East - b.West)
	switch {
	case area <= 25:
		return 1
	case area <= 100:
		return 2
	case area <= 400:
		return 3
	default:
		return 4
	}
}

// Run sweeps the coverage box until ctx ends.
func (o *OpenSky) Run(ctx context.Context) {
	o.init()
	if o.Log != nil {
		o.Log.Info("opensky sweep", "interval", o.SweepInterval, "daily_credits", o.DailyCredits, "auth", o.ClientID != "")
	}
	for {
		if err := o.fetch(ctx, o.Coverage); err != nil && !errors.Is(err, context.Canceled) {
			o.Hub.Fail(KindFlight, "opensky", err)
			if o.Log != nil {
				o.Log.Warn("opensky sweep", "err", err)
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(o.SweepInterval):
		}
	}
}

// EnsureFresh refreshes the area around p (radius km) when it is older than
// RegionMaxAge, waiting at most wait for the answer. Errors are swallowed:
// callers serve whatever the hub has.
func (o *OpenSky) EnsureFresh(ctx context.Context, p geo.Point, radiusKm float64, wait time.Duration) {
	o.init()
	o.mu.Lock()
	c := cell{int(math.Floor(p.Lon)), int(math.Floor(p.Lat))}
	if time.Since(o.regions[c]) < o.RegionMaxAge {
		o.mu.Unlock()
		return
	}
	ch, running := o.inflight[c]
	if !running {
		ch = make(chan struct{})
		o.inflight[c] = ch
		o.regions[c] = time.Now() // claim, even if it fails, to avoid hammering
		box := geo.BoundingBox(p, math.Max(radiusKm*1.5, 60))
		go func() {
			bg, cancel := context.WithTimeout(context.Background(), 25*time.Second)
			defer cancel()
			if err := o.fetch(bg, box); err != nil && o.Log != nil {
				o.Log.Debug("opensky region", "err", err)
			}
			o.mu.Lock()
			delete(o.inflight, c)
			o.mu.Unlock()
			close(ch)
		}()
	}
	o.mu.Unlock()
	select {
	case <-ch:
	case <-time.After(wait):
	case <-ctx.Done():
	}
}

func (o *OpenSky) takeCredits(n int) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	now := time.Now()
	if now.Before(o.blockedTill) {
		return false
	}
	// OpenSky's day is UTC.
	d := now.UTC().Format("2006-01-02")
	if d != o.day {
		o.day, o.used = d, 0
	}
	if o.used+n > o.DailyCredits {
		return false
	}
	o.used += n
	return true
}

// Usage reports today's credit use.
func (o *OpenSky) Usage() map[string]any {
	o.init()
	o.mu.Lock()
	defer o.mu.Unlock()
	return map[string]any{
		"credits_used_today": o.used, "daily_credits": o.DailyCredits,
		"sweep_interval_s": int(o.SweepInterval.Seconds()), "authenticated": o.ClientID != "",
	}
}

func (o *OpenSky) refund(n int) {
	o.mu.Lock()
	o.used = max(0, o.used-n)
	o.mu.Unlock()
}

func (o *OpenSky) fetch(ctx context.Context, b geo.BBox) error {
	cost := Credits(b)
	if !o.takeCredits(cost) {
		return ErrNoCredits
	}
	q := url.Values{
		"lamin": {f4(b.South)}, "lomin": {f4(b.West)},
		"lamax": {f4(b.North)}, "lomax": {f4(b.East)},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, o.BaseURL+"/states/all?"+q.Encode(), nil)
	if err != nil {
		return err
	}
	if o.ClientID != "" {
		tok, err := o.accessToken(ctx)
		if err != nil {
			o.refund(cost)
			return err
		}
		req.Header.Set("Authorization", "Bearer "+tok)
	}
	res, err := o.Client.Do(req)
	if err != nil {
		o.refund(cost) // never reached OpenSky
		return err
	}
	defer res.Body.Close()
	if res.StatusCode >= 500 {
		o.refund(cost)
	}
	if res.StatusCode == http.StatusTooManyRequests {
		wait := 5 * time.Minute
		if s, err := strconv.Atoi(res.Header.Get("X-Rate-Limit-Retry-After-Seconds")); err == nil && s > 0 {
			wait = time.Duration(s) * time.Second
		}
		o.mu.Lock()
		o.blockedTill = time.Now().Add(wait)
		o.mu.Unlock()
		return fmt.Errorf("opensky: rate limited for %s", wait)
	}
	if res.StatusCode/100 != 2 {
		return fmt.Errorf("opensky: HTTP %d", res.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, 32<<20))
	if err != nil {
		return err
	}
	objs, err := ParseOpenSky(body)
	if err != nil {
		return err
	}
	o.Hub.Upsert(KindFlight, "opensky", objs, FlightExpire)
	return nil
}

func (o *OpenSky) accessToken(ctx context.Context) (string, error) {
	o.mu.Lock()
	if o.token != "" && time.Now().Before(o.tokenExp) {
		t := o.token
		o.mu.Unlock()
		return t, nil
	}
	o.mu.Unlock()
	form := url.Values{"grant_type": {"client_credentials"}, "client_id": {o.ClientID}, "client_secret": {o.ClientSecret}}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, o.TokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	res, err := o.Client.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	if res.StatusCode/100 != 2 {
		return "", fmt.Errorf("opensky token: HTTP %d", res.StatusCode)
	}
	var tr struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.NewDecoder(res.Body).Decode(&tr); err != nil || tr.AccessToken == "" {
		return "", fmt.Errorf("opensky token: bad response")
	}
	o.mu.Lock()
	o.token = tr.AccessToken
	o.tokenExp = time.Now().Add(time.Duration(max(60, tr.ExpiresIn-60)) * time.Second)
	o.mu.Unlock()
	return tr.AccessToken, nil
}

// ParseOpenSky converts a states response into flight objects. Rows without
// a position are skipped. Row layout: 0 icao24, 1 callsign, 2 country,
// 3 time_position, 4 last_contact, 5 lon, 6 lat, 7 baro_alt, 8 on_ground,
// 9 velocity m/s, 10 true_track, 11 vertical_rate, 12 sensors,
// 13 geo_alt, 14 squawk, 15 spi, 16 position_source.
func ParseOpenSky(body []byte) ([]Object, error) {
	var doc struct {
		Time   int64   `json:"time"`
		States [][]any `json:"states"`
	}
	if err := json.Unmarshal(body, &doc); err != nil {
		return nil, fmt.Errorf("opensky: %w", err)
	}
	out := make([]Object, 0, len(doc.States))
	for _, r := range doc.States {
		if len(r) < 11 {
			continue
		}
		lon, ok1 := num(r[5])
		lat, ok2 := num(r[6])
		if !ok1 || !ok2 {
			continue
		}
		icao, _ := r[0].(string)
		cs, _ := r[1].(string)
		cs = strings.TrimSpace(cs)
		country, _ := r[2].(string)
		fix := doc.Time
		if t, ok := num(r[3]); ok {
			fix = int64(t)
		} else if t, ok := num(r[4]); ok {
			fix = int64(t)
		}
		var alt *float64
		if len(r) > 13 {
			if a, ok := num(r[13]); ok {
				alt = &a
			}
		}
		if alt == nil {
			if a, ok := num(r[7]); ok {
				alt = &a
			}
		}
		ground, _ := r[8].(bool)
		vel, _ := num(r[9])
		track, _ := num(r[10])
		label := cs
		if label == "" {
			label = strings.ToUpper(icao)
		}
		status := "airborne"
		if ground {
			status = "on_ground"
		}
		out = append(out, Object{
			ID:         icao,
			Label:      label,
			Point:      geo.Point{Lat: lat, Lon: lon},
			HeadingDeg: track,
			SpeedKmh:   vel * 3.6,
			AltitudeM:  alt,
			OnGround:   ground,
			Status:     status,
			Source:     "opensky",
			FixTime:    time.Unix(fix, 0).UTC(),
			DeadReckon: true,
			Extra:      map[string]any{"country": country, "icao24": icao},
		})
	}
	return out, nil
}

func num(v any) (float64, bool) {
	f, ok := v.(float64)
	return f, ok
}

func f4(v float64) string { return strconv.FormatFloat(v, 'f', 4, 64) }
