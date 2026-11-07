// Package live holds the current position of every live object the backend
// tracks (trains, flights, …) in an in-memory spatial index, fed by
// background sources, and answers "what is near here / in this box".
package live

import (
	"math"
	"sort"
	"sync"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// Kind of live object.
type Kind string

const (
	KindTrain  Kind = "train"
	KindFlight Kind = "flight"
)

// Object is one live thing at a position.
type Object struct {
	ID         string         `json:"id"`
	Kind       Kind           `json:"kind"`
	Point      geo.Point      `json:"location"`
	HeadingDeg float64        `json:"heading_deg"`
	SpeedKmh   float64        `json:"speed_kmh"`
	AltitudeM  *float64       `json:"altitude_m,omitempty"`
	OnGround   bool           `json:"on_ground,omitempty"`
	Label      string         `json:"label"`            // "12951", "AIC138"
	Name       string         `json:"name,omitempty"`   // "Mumbai Rajdhani", "DEL → BOM"
	Status     string         `json:"status,omitempty"` // running / at_station / airborne
	DelayMin   *int           `json:"delay_min,omitempty"`
	PrevStop   string         `json:"prev_stop,omitempty"`
	NextStop   string         `json:"next_stop,omitempty"`
	Source     string         `json:"source"`
	Estimated  bool           `json:"estimated"`
	FixTime    time.Time      `json:"fix_time"` // time of the underlying position fix
	Extra      map[string]any `json:"extra,omitempty"`

	// DeadReckon: extrapolate along heading at query time (flights).
	DeadReckon bool `json:"-"`
}

// Result is an object returned by a query, positioned at the query time.
type Result struct {
	Object
	DistanceKm *float64 `json:"distance_km,omitempty"`
}

// LayerStatus describes one kind's feed.
type LayerStatus struct {
	Kind      Kind      `json:"kind"`
	Count     int       `json:"count"`
	UpdatedAt time.Time `json:"updated_at"`
	LastError string    `json:"last_error,omitempty"`
	Source    string    `json:"source,omitempty"`
}

const cellDeg = 0.5

type cell struct{ x, y int }

func cellOf(p geo.Point) cell {
	return cell{int(math.Floor(p.Lon / cellDeg)), int(math.Floor(p.Lat / cellDeg))}
}

type layer struct {
	objs    map[string]Object
	grid    map[cell][]string
	updated time.Time
	lastErr string
	source  string
	// expire: objects not refreshed within this are dropped (upsert layers).
	expire time.Duration
}

// Hub stores the layers. Safe for concurrent use.
type Hub struct {
	mu     sync.RWMutex
	layers map[Kind]*layer
	now    func() time.Time
	// MaxDeadReckon caps extrapolation of stale fixes.
	MaxDeadReckon time.Duration
}

// NewHub creates an empty hub.
func NewHub() *Hub {
	return &Hub{layers: map[Kind]*layer{}, now: time.Now, MaxDeadReckon: 3 * time.Minute}
}

// SetClock replaces the clock (tests).
func (h *Hub) SetClock(now func() time.Time) { h.now = now }

func (h *Hub) layer(k Kind) *layer {
	l := h.layers[k]
	if l == nil {
		l = &layer{objs: map[string]Object{}, grid: map[cell][]string{}}
		h.layers[k] = l
	}
	return l
}

// Replace swaps a kind's whole snapshot (sources that see everything).
func (h *Hub) Replace(k Kind, source string, objs []Object) {
	h.mu.Lock()
	defer h.mu.Unlock()
	l := h.layer(k)
	l.objs = make(map[string]Object, len(objs))
	for _, o := range objs {
		o.Kind = k
		l.objs[o.ID] = o
	}
	l.rebuild()
	l.updated = h.now()
	l.lastErr = ""
	l.source = source
}

// Upsert merges objects into a kind (sources that fetch regions) and drops
// objects older than expire.
func (h *Hub) Upsert(k Kind, source string, objs []Object, expire time.Duration) {
	h.mu.Lock()
	defer h.mu.Unlock()
	l := h.layer(k)
	l.expire = expire
	for _, o := range objs {
		o.Kind = k
		l.objs[o.ID] = o
	}
	if expire > 0 {
		cut := h.now().Add(-expire)
		for id, o := range l.objs {
			if o.FixTime.Before(cut) {
				delete(l.objs, id)
			}
		}
	}
	l.rebuild()
	l.updated = h.now()
	l.lastErr = ""
	l.source = source
}

// Fail records a source error (the last good data stays).
func (h *Hub) Fail(k Kind, source string, err error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	l := h.layer(k)
	l.lastErr = err.Error()
	l.source = source
}

func (l *layer) rebuild() {
	l.grid = make(map[cell][]string, len(l.grid))
	for id, o := range l.objs {
		c := cellOf(o.Point)
		l.grid[c] = append(l.grid[c], id)
	}
}

// Status of every layer.
func (h *Hub) Status() []LayerStatus {
	h.mu.RLock()
	defer h.mu.RUnlock()
	out := make([]LayerStatus, 0, len(h.layers))
	for k, l := range h.layers {
		out = append(out, LayerStatus{Kind: k, Count: len(l.objs), UpdatedAt: l.updated, LastError: l.lastErr, Source: l.source})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Kind < out[j].Kind })
	return out
}

// Updated returns when a kind was last refreshed.
func (h *Hub) Updated(k Kind) time.Time {
	h.mu.RLock()
	defer h.mu.RUnlock()
	if l := h.layers[k]; l != nil {
		return l.updated
	}
	return time.Time{}
}

// Query selects objects.
type Query struct {
	Center   *geo.Point
	RadiusKm float64
	BBox     *geo.BBox
	Kinds    []Kind // empty = all
	Limit    int
	At       time.Time // zero = now
}

// Find returns objects matching q, positioned at q.At (flights dead-
// reckoned), nearest first when a centre is given.
func (h *Hub) Find(q Query) []Result {
	at := q.At
	if at.IsZero() {
		at = h.now()
	}
	var box geo.BBox
	switch {
	case q.Center != nil:
		// Margin for objects that dead-reckon into the circle.
		box = geo.BoundingBox(*q.Center, q.RadiusKm+20)
	case q.BBox != nil:
		box = *q.BBox
	default:
		return nil
	}
	want := map[Kind]bool{}
	for _, k := range q.Kinds {
		want[k] = true
	}

	h.mu.RLock()
	var out []Result
	for k, l := range h.layers {
		if len(want) > 0 && !want[k] {
			continue
		}
		minC := cellOf(geo.Point{Lat: box.South, Lon: box.West})
		maxC := cellOf(geo.Point{Lat: box.North, Lon: box.East})
		for x := minC.x; x <= maxC.x; x++ {
			for y := minC.y; y <= maxC.y; y++ {
				for _, id := range l.grid[cell{x, y}] {
					o := h.positioned(l.objs[id], at)
					r := Result{Object: o}
					if q.Center != nil {
						d := math.Round(geo.HaversineKm(*q.Center, o.Point)*1000) / 1000
						if d > q.RadiusKm {
							continue
						}
						r.DistanceKm = &d
					} else if !box.Contains(o.Point) {
						continue
					}
					out = append(out, r)
				}
			}
		}
	}
	h.mu.RUnlock()

	if q.Center != nil {
		sort.Slice(out, func(i, j int) bool { return *out[i].DistanceKm < *out[j].DistanceKm })
	} else {
		sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	}
	if q.Limit > 0 && len(out) > q.Limit {
		out = out[:q.Limit]
	}
	return out
}

// Get returns one object by kind and id.
func (h *Hub) Get(k Kind, id string) (Object, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	l := h.layers[k]
	if l == nil {
		return Object{}, false
	}
	o, ok := l.objs[id]
	if !ok {
		return Object{}, false
	}
	return h.positioned(o, h.now()), true
}

func (h *Hub) positioned(o Object, at time.Time) Object {
	if !o.DeadReckon || o.OnGround || o.SpeedKmh <= 0 {
		return o
	}
	dt := at.Sub(o.FixTime)
	if dt <= 0 {
		return o
	}
	if dt > h.MaxDeadReckon {
		dt = h.MaxDeadReckon
	}
	o.Point = destination(o.Point, o.HeadingDeg, o.SpeedKmh*dt.Hours())
	o.Estimated = true
	return o
}

// destination moves p by km along bearing.
func destination(p geo.Point, bearing, km float64) geo.Point {
	d := km / geo.EarthRadiusKm
	br := bearing * math.Pi / 180
	la := p.Lat * math.Pi / 180
	lo := p.Lon * math.Pi / 180
	lat2 := math.Asin(math.Sin(la)*math.Cos(d) + math.Cos(la)*math.Sin(d)*math.Cos(br))
	lon2 := lo + math.Atan2(math.Sin(br)*math.Sin(d)*math.Cos(la), math.Cos(d)-math.Sin(la)*math.Sin(lat2))
	return geo.Point{Lat: lat2 * 180 / math.Pi, Lon: math.Mod(lon2*180/math.Pi+540, 360) - 180}
}
