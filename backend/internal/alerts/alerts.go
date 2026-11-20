// Package alerts sends push notifications when something a device cares
// about happens near it: a train comes within range, a flight passes
// overhead, or a watched train is running late.
package alerts

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
	"github.com/dilshadahmad2/nearby-live/backend/internal/live"
)

// Subscription is one device's alert settings.
type Subscription struct {
	DeviceToken  string    `json:"device_token"`
	Platform     string    `json:"platform"`
	Location     geo.Point `json:"location"`
	TrainKm      float64   `json:"train_km"`      // alert when a train is within this; 0 = off
	FlightKm     float64   `json:"flight_km"`     // alert when a flight is within this; 0 = off
	LateMin      int       `json:"late_min"`      // alert when a watched train is this late; 0 = off
	TrainNumbers []string  `json:"train_numbers"` // empty = any train for the distance alert
	QuietStart   int       `json:"quiet_start"`   // local hour 0–23, -1 = none
	QuietEnd     int       `json:"quiet_end"`
	TZOffsetMin  int       `json:"tz_offset_min"` // minutes east of UTC (IST = 330)
	UpdatedAt    time.Time `json:"updated_at"`
}

// Validate normalises and checks a subscription.
func (s *Subscription) Validate() error {
	s.DeviceToken = strings.TrimSpace(s.DeviceToken)
	if len(s.DeviceToken) < 8 || len(s.DeviceToken) > 4096 {
		return errors.New("device_token is required")
	}
	if s.Location.Lat < -90 || s.Location.Lat > 90 || s.Location.Lon < -180 || s.Location.Lon > 180 {
		return errors.New("location out of range")
	}
	if s.TrainKm < 0 || s.TrainKm > 50 || s.FlightKm < 0 || s.FlightKm > 50 {
		return errors.New("train_km and flight_km must be 0–50")
	}
	if s.LateMin < 0 || s.LateMin > 1440 {
		return errors.New("late_min must be 0–1440")
	}
	if len(s.TrainNumbers) > 50 {
		return errors.New("at most 50 train_numbers")
	}
	for i, n := range s.TrainNumbers {
		s.TrainNumbers[i] = strings.TrimSpace(n)
	}
	if s.QuietStart < -1 || s.QuietStart > 23 || s.QuietEnd < -1 || s.QuietEnd > 23 {
		return errors.New("quiet hours must be -1 or 0–23")
	}
	return nil
}

func (s Subscription) watches(number string) bool {
	for _, n := range s.TrainNumbers {
		if n == number {
			return true
		}
	}
	return false
}

// quiet reports whether t falls in the quiet hours.
func (s Subscription) quiet(t time.Time) bool {
	if s.QuietStart < 0 || s.QuietEnd < 0 || s.QuietStart == s.QuietEnd {
		return false
	}
	h := t.In(time.FixedZone("", s.TZOffsetMin*60)).Hour()
	if s.QuietStart < s.QuietEnd {
		return h >= s.QuietStart && h < s.QuietEnd
	}
	return h >= s.QuietStart || h < s.QuietEnd // wraps midnight, e.g. 22–7
}

// Event is one notification.
type Event struct {
	Key   string            `json:"key"` // dedupe key, e.g. "train-near:12951"
	Title string            `json:"title"`
	Body  string            `json:"body"`
	Data  map[string]string `json:"data"`
}

// Evaluate returns the alerts a subscription should get given the live
// objects around it (pure; deduplication happens in [Worker]).
func Evaluate(s Subscription, objs []live.Result) []Event {
	var out []Event
	for _, o := range objs {
		d := geo.HaversineKm(s.Location, o.Point)
		switch o.Kind {
		case live.KindTrain:
			name := o.Name
			if name == "" {
				name = "Train " + o.Label
			}
			delay := ""
			if o.DelayMin != nil && *o.DelayMin > 0 {
				delay = fmt.Sprintf(" · %d min late", *o.DelayMin)
			}
			if s.TrainKm > 0 && d <= s.TrainKm && (len(s.TrainNumbers) == 0 || s.watches(o.ID)) {
				out = append(out, Event{
					Key:   "train-near:" + o.ID,
					Title: "Train nearby",
					Body:  fmt.Sprintf("%s (%s) is %.1f km away%s", name, o.Label, d, delay),
					Data:  map[string]string{"kind": "train", "id": o.ID},
				})
			}
			if s.LateMin > 0 && s.watches(o.ID) && o.DelayMin != nil && *o.DelayMin >= s.LateMin {
				out = append(out, Event{
					Key:   fmt.Sprintf("train-late:%s:%d", o.ID, *o.DelayMin/15), // re-alert every +15 min
					Title: "Train running late",
					Body:  fmt.Sprintf("%s (%s) is running %d min late", name, o.Label, *o.DelayMin),
					Data:  map[string]string{"kind": "train", "id": o.ID},
				})
			}
		case live.KindFlight:
			if s.FlightKm > 0 && d <= s.FlightKm && !o.OnGround {
				alt := ""
				if o.AltitudeM != nil {
					alt = fmt.Sprintf(" at %.1f km", *o.AltitudeM/1000)
				}
				out = append(out, Event{
					Key:   "flight-near:" + o.ID,
					Title: "Flight overhead",
					Body:  fmt.Sprintf("%s is %.1f km away%s", o.Label, d, alt),
					Data:  map[string]string{"kind": "flight", "id": o.ID},
				})
			}
		}
	}
	return out
}

// ErrInvalidToken means the device token is no longer valid; the
// subscription should be removed.
var ErrInvalidToken = errors.New("device token is no longer valid")

// Notifier delivers one event to one device.
type Notifier interface {
	Send(ctx context.Context, s Subscription, e Event) error
}

// Store keeps subscriptions.
type Store interface {
	Put(ctx context.Context, s Subscription) error
	Get(ctx context.Context, token string) (Subscription, bool, error)
	Delete(ctx context.Context, token string) error
	All(ctx context.Context) ([]Subscription, error)
}

// MemStore is an in-memory [Store] (CSV mode, tests).
type MemStore struct {
	mu   sync.Mutex
	subs map[string]Subscription
}

func (m *MemStore) Put(_ context.Context, s Subscription) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.subs == nil {
		m.subs = map[string]Subscription{}
	}
	m.subs[s.DeviceToken] = s
	return nil
}

func (m *MemStore) Get(_ context.Context, t string) (Subscription, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.subs[t]
	return s, ok, nil
}

func (m *MemStore) Delete(_ context.Context, t string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.subs, t)
	return nil
}

func (m *MemStore) All(context.Context) ([]Subscription, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]Subscription, 0, len(m.subs))
	for _, s := range m.subs {
		out = append(out, s)
	}
	return out, nil
}

// Worker evaluates every subscription against the hub periodically.
type Worker struct {
	Hub      *live.Hub
	Store    Store
	Notifier Notifier
	Interval time.Duration // default 30 s
	Cooldown time.Duration // same event key not repeated within (default 1 h)
	Log      *slog.Logger
	Now      func() time.Time

	mu   sync.Mutex
	sent map[string]time.Time // token|key → when
	n    uint64
}

// Sent is the number of notifications delivered.
func (w *Worker) Sent() uint64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.n
}

// Run loops until ctx ends.
func (w *Worker) Run(ctx context.Context) {
	if w.Interval <= 0 {
		w.Interval = 30 * time.Second
	}
	t := time.NewTicker(w.Interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			w.Tick(ctx)
		}
	}
}

// Tick runs one evaluation pass.
func (w *Worker) Tick(ctx context.Context) {
	now := time.Now()
	if w.Now != nil {
		now = w.Now()
	}
	cool := w.Cooldown
	if cool <= 0 {
		cool = time.Hour
	}
	subs, err := w.Store.All(ctx)
	if err != nil {
		w.log().Warn("alerts: load subscriptions", "err", err)
		return
	}
	w.mu.Lock()
	if w.sent == nil {
		w.sent = map[string]time.Time{}
	}
	for k, t := range w.sent { // forget old keys
		if now.Sub(t) > 2*cool {
			delete(w.sent, k)
		}
	}
	w.mu.Unlock()

	for _, s := range subs {
		radius := max(s.TrainKm, s.FlightKm)
		if s.LateMin > 0 && len(s.TrainNumbers) > 0 {
			radius = max(radius, 200) // late alerts apply to watched trains anywhere nearby-ish
		}
		if radius <= 0 || s.quiet(now) {
			continue
		}
		loc := s.Location
		objs := w.Hub.Find(live.Query{Center: &loc, RadiusKm: radius, Kinds: []live.Kind{live.KindTrain, live.KindFlight}, Limit: 500})
		for _, e := range Evaluate(s, objs) {
			k := s.DeviceToken + "|" + e.Key
			w.mu.Lock()
			last, seen := w.sent[k]
			if seen && now.Sub(last) < cool {
				w.mu.Unlock()
				continue
			}
			w.sent[k] = now
			w.mu.Unlock()
			err := w.Notifier.Send(ctx, s, e)
			switch {
			case errors.Is(err, ErrInvalidToken):
				_ = w.Store.Delete(ctx, s.DeviceToken)
				w.log().Info("alerts: removed invalid device token")
			case err != nil:
				w.log().Warn("alerts: send", "err", err)
				w.mu.Lock()
				delete(w.sent, k) // retry next tick
				w.mu.Unlock()
			default:
				w.mu.Lock()
				w.n++
				w.mu.Unlock()
			}
			if errors.Is(err, ErrInvalidToken) {
				break
			}
		}
	}
}

func (w *Worker) log() *slog.Logger {
	if w.Log != nil {
		return w.Log
	}
	return slog.Default()
}

// LogNotifier only logs (used when no push service is configured).
type LogNotifier struct{ Log *slog.Logger }

func (l LogNotifier) Send(_ context.Context, s Subscription, e Event) error {
	lg := l.Log
	if lg == nil {
		lg = slog.Default()
	}
	lg.Info("alert (no push service configured)", "platform", s.Platform, "title", e.Title, "body", e.Body)
	return nil
}
