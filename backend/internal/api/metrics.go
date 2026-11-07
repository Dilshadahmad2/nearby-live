package api

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"time"
)

// metrics is a tiny Prometheus-text exporter (no client library needed).
type metrics struct {
	mu       sync.Mutex
	requests map[[3]string]uint64 // method, route, status class
	latency  map[string]*hist     // route
	started  time.Time
}

type hist struct {
	buckets []float64
	counts  []uint64
	sum     float64
	n       uint64
}

var latencyBuckets = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5}

func newMetrics() *metrics {
	return &metrics{requests: map[[3]string]uint64{}, latency: map[string]*hist{}, started: time.Now()}
}

func (m *metrics) observe(method, route string, status int, d time.Duration) {
	if route == "" {
		route = "unmatched"
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.requests[[3]string{method, route, fmt.Sprintf("%dxx", status/100)}]++
	h := m.latency[route]
	if h == nil {
		h = &hist{buckets: latencyBuckets, counts: make([]uint64, len(latencyBuckets))}
		m.latency[route] = h
	}
	s := d.Seconds()
	for i, b := range h.buckets {
		if s <= b {
			h.counts[i]++
		}
	}
	h.sum += s
	h.n++
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (r *statusRecorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

// Hijack is needed by the WebSocket upgrade (it type-asserts http.Hijacker).
func (r *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	hj, ok := r.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, errors.New("hijack not supported")
	}
	r.status = http.StatusSwitchingProtocols
	return hj.Hijack()
}

// Flush passes through for streaming responses.
func (r *statusRecorder) Flush() {
	if f, ok := r.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func esc(v string) string { return strings.NewReplacer(`\`, `\\`, `"`, `\"`, "\n", `\n`).Replace(v) }

// serveMetrics writes GET /metrics.
func (s *Server) serveMetrics(w http.ResponseWriter, _ *http.Request) {
	var b strings.Builder
	m := s.metrics

	m.mu.Lock()
	b.WriteString("# HELP nearby_http_requests_total HTTP requests by route and status class.\n# TYPE nearby_http_requests_total counter\n")
	keys := make([][3]string, 0, len(m.requests))
	for k := range m.requests {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool { return strings.Join(keys[i][:], " ") < strings.Join(keys[j][:], " ") })
	for _, k := range keys {
		fmt.Fprintf(&b, "nearby_http_requests_total{method=%q,route=%q,status=%q} %d\n", esc(k[0]), esc(k[1]), k[2], m.requests[k])
	}
	b.WriteString("# HELP nearby_http_request_duration_seconds Request latency.\n# TYPE nearby_http_request_duration_seconds histogram\n")
	routes := make([]string, 0, len(m.latency))
	for r := range m.latency {
		routes = append(routes, r)
	}
	sort.Strings(routes)
	for _, r := range routes {
		h := m.latency[r]
		for i, le := range h.buckets {
			fmt.Fprintf(&b, "nearby_http_request_duration_seconds_bucket{route=%q,le=\"%g\"} %d\n", esc(r), le, h.counts[i])
		}
		fmt.Fprintf(&b, "nearby_http_request_duration_seconds_bucket{route=%q,le=\"+Inf\"} %d\n", esc(r), h.n)
		fmt.Fprintf(&b, "nearby_http_request_duration_seconds_sum{route=%q} %g\n", esc(r), h.sum)
		fmt.Fprintf(&b, "nearby_http_request_duration_seconds_count{route=%q} %d\n", esc(r), h.n)
	}
	started := m.started
	m.mu.Unlock()

	now := s.Now()
	b.WriteString("# HELP nearby_live_objects Live objects held per kind.\n# TYPE nearby_live_objects gauge\n")
	b.WriteString("# HELP nearby_live_age_seconds Seconds since a kind was last refreshed.\n# TYPE nearby_live_age_seconds gauge\n")
	b.WriteString("# HELP nearby_live_feed_error 1 when the last refresh of a kind failed.\n# TYPE nearby_live_feed_error gauge\n")
	for _, l := range s.Hub.Status() {
		fmt.Fprintf(&b, "nearby_live_objects{kind=%q} %d\n", l.Kind, l.Count)
		if !l.UpdatedAt.IsZero() {
			fmt.Fprintf(&b, "nearby_live_age_seconds{kind=%q} %g\n", l.Kind, now.Sub(l.UpdatedAt).Seconds())
		}
		e := 0
		if l.LastError != "" {
			e = 1
		}
		fmt.Fprintf(&b, "nearby_live_feed_error{kind=%q} %d\n", l.Kind, e)
	}
	if s.Stream != nil {
		fmt.Fprintf(&b, "# HELP nearby_stream_connections Open WebSocket streams.\n# TYPE nearby_stream_connections gauge\nnearby_stream_connections %d\n", s.Stream.Conns())
	}
	ds := s.Delays.Stats()
	fmt.Fprintf(&b, "# HELP nearby_delay_provider_requests_today Delay provider requests used today.\n# TYPE nearby_delay_provider_requests_today gauge\nnearby_delay_provider_requests_today %d\n", ds.RequestsToday)
	fmt.Fprintf(&b, "# HELP nearby_delay_cached Live train statuses cached.\n# TYPE nearby_delay_cached gauge\nnearby_delay_cached %d\n", ds.Cached)
	if s.Sky != nil {
		u := s.Sky.Usage()
		fmt.Fprintf(&b, "# HELP nearby_opensky_credits_used_today OpenSky credits used today (UTC).\n# TYPE nearby_opensky_credits_used_today gauge\nnearby_opensky_credits_used_today %v\n", u["credits_used_today"])
		fmt.Fprintf(&b, "# HELP nearby_opensky_daily_credits OpenSky daily credit budget.\n# TYPE nearby_opensky_daily_credits gauge\nnearby_opensky_daily_credits %v\n", u["daily_credits"])
	}
	if s.Traffic != nil {
		u := s.Traffic.Usage()
		fmt.Fprintf(&b, "# HELP nearby_tomtom_requests_today TomTom requests used today (UTC).\n# TYPE nearby_tomtom_requests_today gauge\nnearby_tomtom_requests_today %v\n", u["requests_today"])
	}
	fmt.Fprintf(&b, "# HELP nearby_uptime_seconds Process uptime.\n# TYPE nearby_uptime_seconds gauge\nnearby_uptime_seconds %g\n", time.Since(started).Seconds())

	w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
	_, _ = w.Write([]byte(b.String()))
}
