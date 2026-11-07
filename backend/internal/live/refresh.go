package live

import (
	"context"
	"math"
	"sync"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// Refresher is a source that fetches the area around a request on demand
// (flights, weather, traffic). Implementations must be cheap to call often:
// they deduplicate per area and rate-limit themselves.
type Refresher interface {
	Kind() Kind
	// EnsureFresh refreshes the area around p when stale, waiting at most
	// wait (0 = don't wait) for the result.
	EnsureFresh(ctx context.Context, p geo.Point, radiusKm float64, wait time.Duration)
}

// Refreshers is a set of on-demand sources.
type Refreshers []Refresher

// Ensure runs every refresher whose kind is wanted (all when kinds is
// empty) in parallel and returns after at most wait.
func (rs Refreshers) Ensure(ctx context.Context, kinds []Kind, p geo.Point, radiusKm float64, wait time.Duration) {
	want := map[Kind]bool{}
	for _, k := range kinds {
		want[k] = true
	}
	var wg sync.WaitGroup
	for _, r := range rs {
		if r == nil || (len(want) > 0 && !want[r.Kind()]) {
			continue
		}
		wg.Add(1)
		go func(r Refresher) {
			defer wg.Done()
			r.EnsureFresh(ctx, p, radiusKm, wait)
		}(r)
	}
	wg.Wait()
}

// areaGate deduplicates and rate-limits refreshes per grid cell.
type areaGate struct {
	mu       sync.Mutex
	last     map[cell]time.Time
	inflight map[cell]chan struct{}
}

// run calls fetch for cell c unless it ran within maxAge; concurrent callers
// for the same cell share one fetch. It waits up to wait for completion.
func (g *areaGate) run(ctx context.Context, c cell, maxAge, wait time.Duration, fetch func(context.Context)) {
	g.mu.Lock()
	if g.last == nil {
		g.last = map[cell]time.Time{}
		g.inflight = map[cell]chan struct{}{}
	}
	if time.Since(g.last[c]) < maxAge {
		g.mu.Unlock()
		return
	}
	ch, running := g.inflight[c]
	if !running {
		ch = make(chan struct{})
		g.inflight[c] = ch
		g.last[c] = time.Now() // claim even if it fails, so errors don't hammer the API
		go func() {
			bg, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			fetch(bg)
			g.mu.Lock()
			delete(g.inflight, c)
			g.mu.Unlock()
			close(ch)
		}()
	}
	g.mu.Unlock()
	if wait <= 0 {
		return
	}
	select {
	case <-ch:
	case <-time.After(wait):
	case <-ctx.Done():
	}
}

// gridCell buckets p into cells of size deg.
func gridCell(p geo.Point, deg float64) cell {
	return cell{int(math.Floor(p.Lon / deg)), int(math.Floor(p.Lat / deg))}
}

// dailyBudget counts requests per UTC day.
type dailyBudget struct {
	mu    sync.Mutex
	limit int
	day   string
	used  int
}

func (b *dailyBudget) take(n int) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.limit <= 0 {
		return true
	}
	d := time.Now().UTC().Format("2006-01-02")
	if d != b.day {
		b.day, b.used = d, 0
	}
	if b.used+n > b.limit {
		return false
	}
	b.used += n
	return true
}

func (b *dailyBudget) usage() (used, limit int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.day != time.Now().UTC().Format("2006-01-02") {
		return 0, b.limit
	}
	return b.used, b.limit
}
