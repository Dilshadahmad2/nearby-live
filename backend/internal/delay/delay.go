// Package delay keeps live running status (delay, last reported station,
// optional live coordinates) for Indian trains. Status arrives either from
// a configured HTTP provider (fetched on demand, cached, budgeted) or is
// pushed in through the admin API by any feed.
package delay

import (
	"context"
	"errors"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// IST is Indian Standard Time.
var IST = time.FixedZone("IST", 5*3600+30*60)

// Status is the live running status of one journey of a train.
type Status struct {
	TrainNumber     string     `json:"train_number"`
	JourneyDate     string     `json:"journey_date"` // YYYY-MM-DD (IST) the train left its origin
	DelayMin        int        `json:"delay_min"`
	LastStationCode string     `json:"last_station_code,omitempty"`
	Point           *geo.Point `json:"location,omitempty"` // when the provider reports coordinates
	Source          string     `json:"source"`
	ReportedAt      time.Time  `json:"reported_at"`
}

// Provider fetches live status for one journey.
type Provider interface {
	Name() string
	Fetch(ctx context.Context, trainNumber string, journeyDate time.Time) (Status, error)
}

// Store persists statuses (optional; nil = memory only).
type Store interface {
	Save(ctx context.Context, s Status) error
	LoadSince(ctx context.Context, since time.Time) ([]Status, error)
}

// Errors.
var (
	ErrNoProvider = errors.New("no live delay provider configured")
	ErrBudget     = errors.New("daily live delay request budget used up")
	ErrNotFound   = errors.New("no live status for this train")
)

// Config for [Service].
type Config struct {
	// TTL: cached status younger than this is served without refetching.
	TTL time.Duration
	// MaxAge: older statuses are ignored completely.
	MaxAge time.Duration
	// DailyLimit caps provider requests per IST day (0 = unlimited).
	DailyLimit int
	// Concurrency caps simultaneous provider requests.
	Concurrency int
}

type key struct{ number, date string }

type call struct {
	done chan struct{}
	st   Status
	err  error
}

// Service caches live status, deduplicates concurrent fetches and enforces
// the provider budget.
type Service struct {
	provider Provider
	store    Store
	cfg      Config
	now      func() time.Time

	mu       sync.Mutex
	cache    map[key]Status
	inflight map[key]*call
	sem      chan struct{}
	day      string
	used     int
}

// NewService creates a service. provider and store may be nil.
func NewService(p Provider, s Store, cfg Config) *Service {
	if cfg.TTL <= 0 {
		cfg.TTL = 3 * time.Minute
	}
	if cfg.MaxAge <= 0 {
		cfg.MaxAge = 6 * time.Hour
	}
	if cfg.Concurrency <= 0 {
		cfg.Concurrency = 4
	}
	return &Service{
		provider: p,
		store:    s,
		cfg:      cfg,
		now:      time.Now,
		cache:    map[key]Status{},
		inflight: map[key]*call{},
		sem:      make(chan struct{}, cfg.Concurrency),
	}
}

// SetClock replaces the clock (tests).
func (s *Service) SetClock(now func() time.Time) { s.now = now }

// HasProvider reports whether on-demand fetching is possible.
func (s *Service) HasProvider() bool { return s.provider != nil }

// ProviderName or "".
func (s *Service) ProviderName() string {
	if s.provider == nil {
		return ""
	}
	return s.provider.Name()
}

// DateKey formats a journey date.
func DateKey(t time.Time) string { return t.In(IST).Format("2006-01-02") }

// Warm loads recent statuses from the store.
func (s *Service) Warm(ctx context.Context) error {
	if s.store == nil {
		return nil
	}
	list, err := s.store.LoadSince(ctx, s.now().Add(-s.cfg.MaxAge))
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, st := range list {
		s.cache[key{st.TrainNumber, st.JourneyDate}] = st
	}
	return nil
}

// Put records a status pushed by a feed (and persists it).
func (s *Service) Put(ctx context.Context, st Status) error {
	st.TrainNumber = strings.TrimSpace(st.TrainNumber)
	if st.ReportedAt.IsZero() {
		st.ReportedAt = s.now()
	}
	if st.JourneyDate == "" {
		st.JourneyDate = DateKey(s.now())
	}
	s.mu.Lock()
	s.cache[key{st.TrainNumber, st.JourneyDate}] = st
	s.mu.Unlock()
	if s.store != nil {
		return s.store.Save(ctx, st)
	}
	return nil
}

// PutLocal caches a status that another instance already persisted.
func (s *Service) PutLocal(st Status) {
	s.mu.Lock()
	defer s.mu.Unlock()
	k := key{st.TrainNumber, st.JourneyDate}
	if old, ok := s.cache[k]; ok && old.ReportedAt.After(st.ReportedAt) {
		return
	}
	s.cache[k] = st
}

// Latest returns the most recent status of any journey of a train that is
// younger than MaxAge, without fetching.
func (s *Service) Latest(number string) (Status, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var best Status
	found := false
	cut := s.now().Add(-s.cfg.MaxAge)
	for k, st := range s.cache {
		if k.number != number || st.ReportedAt.Before(cut) {
			continue
		}
		if !found || st.ReportedAt.After(best.ReportedAt) {
			best, found = st, true
		}
	}
	return best, found
}

// DelayFor is the delay to apply to a train's schedule (0 when unknown).
func (s *Service) DelayFor(number string) time.Duration {
	if st, ok := s.Latest(number); ok {
		return time.Duration(st.DelayMin) * time.Minute
	}
	return 0
}

// Get returns a fresh status for a journey, fetching from the provider when
// the cached one is older than TTL. When fetching is impossible (no
// provider, budget used, provider error) it falls back to a cached status
// younger than MaxAge and returns the error only when it has nothing.
func (s *Service) Get(ctx context.Context, number string, journey time.Time) (Status, error) {
	k := key{strings.TrimSpace(number), DateKey(journey)}
	now := s.now()

	s.mu.Lock()
	cached, have := s.cache[k]
	if have && now.Sub(cached.ReportedAt) < s.cfg.TTL {
		s.mu.Unlock()
		return cached, nil
	}
	fallback := func(err error) (Status, error) {
		if have && now.Sub(cached.ReportedAt) < s.cfg.MaxAge {
			return cached, nil
		}
		return Status{}, err
	}
	if s.provider == nil {
		s.mu.Unlock()
		return fallback(ErrNoProvider)
	}
	if c, ok := s.inflight[k]; ok { // someone is already fetching it
		s.mu.Unlock()
		select {
		case <-c.done:
		case <-ctx.Done():
			return fallback(ctx.Err())
		}
		if c.err != nil {
			return fallback(c.err)
		}
		return c.st, nil
	}
	if !s.takeBudgetLocked(now) {
		s.mu.Unlock()
		return fallback(ErrBudget)
	}
	c := &call{done: make(chan struct{})}
	s.inflight[k] = c
	s.mu.Unlock()

	select {
	case s.sem <- struct{}{}:
		c.st, c.err = s.provider.Fetch(ctx, k.number, journey)
		<-s.sem
	case <-ctx.Done():
		c.err = ctx.Err()
	}
	if c.err == nil {
		c.st.TrainNumber = k.number
		c.st.JourneyDate = k.date
		if c.st.Source == "" {
			c.st.Source = s.provider.Name()
		}
		if c.st.ReportedAt.IsZero() {
			c.st.ReportedAt = s.now()
		}
	}

	s.mu.Lock()
	delete(s.inflight, k)
	if c.err == nil {
		s.cache[k] = c.st
	}
	s.mu.Unlock()
	close(c.done)

	if c.err != nil {
		return fallback(c.err)
	}
	if s.store != nil {
		_ = s.store.Save(context.WithoutCancel(ctx), c.st)
	}
	return c.st, nil
}

func (s *Service) takeBudgetLocked(now time.Time) bool {
	if s.cfg.DailyLimit <= 0 {
		return true
	}
	d := DateKey(now)
	if d != s.day {
		s.day, s.used = d, 0
	}
	if s.used >= s.cfg.DailyLimit {
		return false
	}
	s.used++
	return true
}

// Stats for health output.
type Stats struct {
	Provider      string `json:"provider,omitempty"`
	Cached        int    `json:"cached"`
	RequestsToday int    `json:"provider_requests_today"`
	DailyLimit    int    `json:"provider_daily_limit"`
}

// Stats returns counters.
func (s *Service) Stats() Stats {
	s.mu.Lock()
	defer s.mu.Unlock()
	used := s.used
	if s.day != DateKey(s.now()) {
		used = 0
	}
	return Stats{Provider: s.ProviderName(), Cached: len(s.cache), RequestsToday: used, DailyLimit: s.cfg.DailyLimit}
}

// Recent lists cached statuses reported after since, newest first.
func (s *Service) Recent(since time.Time, limit int) []Status {
	s.mu.Lock()
	out := make([]Status, 0, len(s.cache))
	for _, st := range s.cache {
		if st.ReportedAt.After(since) {
			out = append(out, st)
		}
	}
	s.mu.Unlock()
	sort.Slice(out, func(i, j int) bool { return out[i].ReportedAt.After(out[j].ReportedAt) })
	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out
}
