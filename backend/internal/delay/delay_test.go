package delay

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestParseMinutes(t *testing.T) {
	cases := map[any]int{
		15.0: 15, "15": 15, "15 min": 15, "1h 5m": 65, "1 hr 5 mins": 65, "01:05": 65,
		"On Time": 0, "RT": 0, "-3": -3, "2 hours": 120,
	}
	for in, want := range cases {
		got, ok := parseMinutes(in)
		if !ok || got != want {
			t.Errorf("parseMinutes(%v) = %d,%v want %d", in, got, ok, want)
		}
	}
	for _, bad := range []any{nil, "", "soon", true} {
		if _, ok := parseMinutes(bad); ok {
			t.Errorf("parseMinutes(%v) should fail", bad)
		}
	}
}

func TestHTTPProviderParsesConfiguredPaths(t *testing.T) {
	var gotURL, gotKey string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotURL = r.URL.String()
		gotKey = r.Header.Get("X-Api-Key")
		w.Write([]byte(`{"status": true, "data": {"delay": "1h 5m", "current_station_code": "kota",
			"location": {"lat": 25.18, "lng": 75.83}}}`))
	}))
	defer srv.Close()
	p := &HTTPProvider{
		ProviderName: "test",
		URLTemplate:  srv.URL + "/live?train={number}&startDay={start_day}&date={date_dmy}",
		Headers:      map[string]string{"X-Api-Key": "k"},
		DelayPath:    "data.delay",
		StationPath:  "data.current_station_code",
		LatPath:      "data.location.lat",
		LonPath:      "data.location.lng",
		OKPath:       "status",
		Now:          func() time.Time { return time.Date(2026, 11, 8, 3, 0, 0, 0, IST) },
	}
	st, err := p.Fetch(context.Background(), "12951", time.Date(2026, 11, 7, 0, 0, 0, 0, IST))
	if err != nil {
		t.Fatal(err)
	}
	if gotURL != "/live?train=12951&startDay=1&date=07-11-2026" || gotKey != "k" {
		t.Fatalf("request %q key %q", gotURL, gotKey)
	}
	if st.DelayMin != 65 || st.LastStationCode != "KOTA" || st.Point == nil || st.Point.Lat != 25.18 {
		t.Fatalf("status = %+v", st)
	}
	if st.JourneyDate != "2026-11-07" || st.Source != "test" {
		t.Fatalf("meta = %+v", st)
	}
}

func TestHTTPProviderReportsFailures(t *testing.T) {
	p := &HTTPProvider{DelayPath: "data.delay", OKPath: "status", MessagePath: "message"}
	if _, err := p.Parse([]byte(`{"status": false, "message": "Train not running"}`)); err == nil || err.Error() != "http: Train not running" {
		t.Fatalf("err = %v", err)
	}
	if _, err := p.Parse([]byte(`{"status": true, "data": {}}`)); err == nil {
		t.Fatal("missing delay should fail")
	}
}

type fakeProvider struct {
	calls atomic.Int32
	delay int
	err   error
	wait  chan struct{}
}

func (f *fakeProvider) Name() string { return "fake" }
func (f *fakeProvider) Fetch(ctx context.Context, n string, j time.Time) (Status, error) {
	f.calls.Add(1)
	if f.wait != nil {
		<-f.wait
	}
	return Status{DelayMin: f.delay}, f.err
}

func TestServiceCachesWithinTTL(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, IST)
	fp := &fakeProvider{delay: 20}
	s := NewService(fp, nil, Config{TTL: 3 * time.Minute, MaxAge: time.Hour})
	s.SetClock(func() time.Time { return now })
	j := now
	for i := 0; i < 3; i++ {
		st, err := s.Get(context.Background(), "12951", j)
		if err != nil || st.DelayMin != 20 {
			t.Fatalf("get: %+v %v", st, err)
		}
	}
	if fp.calls.Load() != 1 {
		t.Fatalf("calls = %d", fp.calls.Load())
	}
	now = now.Add(4 * time.Minute)
	_, _ = s.Get(context.Background(), "12951", j)
	if fp.calls.Load() != 2 {
		t.Fatal("expected a refetch after TTL")
	}
	if s.DelayFor("12951") != 20*time.Minute {
		t.Fatal("DelayFor")
	}
}

func TestServiceDeduplicatesConcurrentFetches(t *testing.T) {
	fp := &fakeProvider{delay: 5, wait: make(chan struct{})}
	s := NewService(fp, nil, Config{})
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if st, err := s.Get(context.Background(), "1", time.Now()); err != nil || st.DelayMin != 5 {
				t.Errorf("get: %+v %v", st, err)
			}
		}()
	}
	time.Sleep(50 * time.Millisecond)
	close(fp.wait)
	wg.Wait()
	if fp.calls.Load() != 1 {
		t.Fatalf("calls = %d, want 1", fp.calls.Load())
	}
}

func TestServiceBudgetAndFallback(t *testing.T) {
	now := time.Date(2026, 11, 7, 12, 0, 0, 0, IST)
	fp := &fakeProvider{delay: 7}
	s := NewService(fp, nil, Config{TTL: time.Minute, MaxAge: time.Hour, DailyLimit: 1})
	s.SetClock(func() time.Time { return now })
	if _, err := s.Get(context.Background(), "A", now); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Get(context.Background(), "B", now); !errors.Is(err, ErrBudget) {
		t.Fatalf("err = %v, want budget", err)
	}
	// Stale but within MaxAge: served from cache when the budget is gone.
	now = now.Add(10 * time.Minute)
	if st, err := s.Get(context.Background(), "A", now.Add(-10*time.Minute)); err != nil || st.DelayMin != 7 {
		t.Fatalf("fallback: %+v %v", st, err)
	}
	// Next IST day: budget resets.
	now = now.Add(24 * time.Hour)
	if _, err := s.Get(context.Background(), "B", now); err != nil {
		t.Fatalf("after reset: %v", err)
	}
}

func TestPushedStatusIsUsed(t *testing.T) {
	s := NewService(nil, nil, Config{})
	if _, err := s.Get(context.Background(), "X", time.Now()); !errors.Is(err, ErrNoProvider) {
		t.Fatalf("err = %v", err)
	}
	_ = s.Put(context.Background(), Status{TrainNumber: "X", DelayMin: 42, Source: "push"})
	if s.DelayFor("X") != 42*time.Minute {
		t.Fatal("pushed delay not applied")
	}
}
