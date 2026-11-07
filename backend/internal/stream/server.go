package stream

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
	"github.com/dilshadahmad2/nearby-live/backend/internal/live"
)

// Config for [Server].
type Config struct {
	MaxConns        int           // default 1000
	MinInterval     time.Duration // default 1 s
	DefaultInterval time.Duration // default 2 s
	MaxRadiusKm     float64       // default 200
	MaxLimit        int           // default 500
	StatusEvery     time.Duration // default 30 s
	PingEvery       time.Duration // default 25 s
	// OriginPatterns for browser clients (native apps send no Origin).
	// Empty = any origin.
	OriginPatterns []string
}

// Server streams the hub to WebSocket clients.
type Server struct {
	Hub *live.Hub
	// Refreshers fetch areas on demand around subscribers (flights, weather, traffic).
	Refreshers live.Refreshers
	Log        *slog.Logger
	Cfg        Config

	conns atomic.Int64
}

func (s *Server) defaults() {
	c := &s.Cfg
	if c.MaxConns <= 0 {
		c.MaxConns = 1000
	}
	if c.MinInterval <= 0 {
		c.MinInterval = time.Second
	}
	if c.DefaultInterval <= 0 {
		c.DefaultInterval = 2 * time.Second
	}
	if c.MaxRadiusKm <= 0 {
		c.MaxRadiusKm = 200
	}
	if c.MaxLimit <= 0 {
		c.MaxLimit = 500
	}
	if c.StatusEvery <= 0 {
		c.StatusEvery = 30 * time.Second
	}
	if c.PingEvery <= 0 {
		c.PingEvery = 25 * time.Second
	}
	if s.Log == nil {
		s.Log = slog.Default()
	}
}

// Conns is the number of open connections.
func (s *Server) Conns() int64 { return s.conns.Load() }

// subscription is a validated "subscribe".
type subscription struct {
	center   geo.Point
	radiusKm float64
	kinds    []live.Kind
	limit    int
	interval time.Duration
}

func (s *Server) parseSub(m ClientMsg) (subscription, error) {
	if m.Lat == nil || m.Lon == nil || *m.Lat < -90 || *m.Lat > 90 || *m.Lon < -180 || *m.Lon > 180 {
		return subscription{}, errors.New("subscribe needs lat and lon in degrees")
	}
	sub := subscription{center: geo.Point{Lat: *m.Lat, Lon: *m.Lon}, radiusKm: m.RadiusKm, limit: m.Limit}
	if sub.radiusKm <= 0 {
		sub.radiusKm = 10
	}
	sub.radiusKm = min(sub.radiusKm, s.Cfg.MaxRadiusKm)
	if sub.limit <= 0 || sub.limit > s.Cfg.MaxLimit {
		sub.limit = min(200, s.Cfg.MaxLimit)
	}
	for _, t := range m.Types {
		if t = strings.TrimSuffix(strings.ToLower(strings.TrimSpace(t)), "s"); t != "" {
			sub.kinds = append(sub.kinds, live.Kind(t))
		}
	}
	sub.interval = s.Cfg.DefaultInterval
	if m.IntervalMs > 0 {
		sub.interval = max(s.Cfg.MinInterval, time.Duration(m.IntervalMs)*time.Millisecond)
	}
	return sub, nil
}

// ServeHTTP upgrades and runs one client.
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.defaults()
	if s.conns.Add(1) > int64(s.Cfg.MaxConns) {
		s.conns.Add(-1)
		http.Error(w, `{"error":"too many live connections"}`, http.StatusServiceUnavailable)
		return
	}
	defer s.conns.Add(-1)

	opts := &websocket.AcceptOptions{OriginPatterns: s.Cfg.OriginPatterns, CompressionMode: websocket.CompressionContextTakeover}
	if len(s.Cfg.OriginPatterns) == 0 {
		opts.InsecureSkipVerify = true // any origin; data is public and read-only
	}
	c, err := websocket.Accept(w, r, opts)
	if err != nil {
		return // Accept already wrote the HTTP error
	}
	c.SetReadLimit(8 << 10)
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()
	err = s.run(ctx, c)
	switch {
	case err == nil, errors.Is(err, context.Canceled), websocket.CloseStatus(err) != -1:
		c.Close(websocket.StatusNormalClosure, "")
	default:
		s.Log.Debug("stream closed", "err", err)
		c.Close(websocket.StatusInternalError, "internal error")
	}
}

func (s *Server) run(ctx context.Context, c *websocket.Conn) error {
	write := func(m ServerMsg) error {
		wctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		b, err := json.Marshal(m)
		if err != nil {
			return err
		}
		return c.Write(wctx, websocket.MessageText, b)
	}
	if err := write(ServerMsg{Type: "hello", Protocol: ProtocolVersion, MinIntervalMs: int(s.Cfg.MinInterval / time.Millisecond)}); err != nil {
		return err
	}

	// Reader: client messages arrive on a channel so one goroutine owns writes.
	msgs := make(chan ClientMsg, 4)
	readErr := make(chan error, 1)
	go func() {
		for {
			_, data, err := c.Read(ctx)
			if err != nil {
				readErr <- err
				return
			}
			var m ClientMsg
			if json.Unmarshal(data, &m) != nil {
				m = ClientMsg{Type: "invalid"}
			}
			select {
			case msgs <- m:
			case <-ctx.Done():
				return
			}
		}
	}()

	var (
		sub    *subscription
		diff   = NewDiffer()
		seq    uint64
		tick   = time.NewTicker(time.Hour) // re-armed on subscribe
		status = time.NewTicker(s.Cfg.StatusEvery)
		ping   = time.NewTicker(s.Cfg.PingEvery)
	)
	defer tick.Stop()
	defer status.Stop()
	defer ping.Stop()

	query := func() []live.Result {
		s.Refreshers.Ensure(ctx, sub.kinds, sub.center, sub.radiusKm, 0) // non-blocking
		c := sub.center
		return s.Hub.FindArea(live.Query{Center: &c, RadiusKm: sub.radiusKm, Kinds: sub.kinds, Limit: sub.limit})
	}

	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case err := <-readErr:
			return err
		case m := <-msgs:
			switch m.Type {
			case "subscribe":
				ns, err := s.parseSub(m)
				if err != nil {
					if err := write(ServerMsg{Type: "error", Message: err.Error()}); err != nil {
						return err
					}
					continue
				}
				first := sub == nil
				sub = &ns
				if first {
					// Give the first snapshot a chance to include fetched areas.
					s.Refreshers.Ensure(ctx, sub.kinds, sub.center, sub.radiusKm, 3*time.Second)
				}
				items := query()
				diff.Snapshot(items)
				seq++
				now := time.Now().UTC()
				if items == nil {
					items = []live.Result{}
				}
				if err := write(ServerMsg{Type: "snapshot", Seq: seq, At: &now, Items: items, Layers: s.Hub.Status()}); err != nil {
					return err
				}
				tick.Reset(sub.interval)
			case "ping":
				if err := write(ServerMsg{Type: "pong"}); err != nil {
					return err
				}
			default:
				if err := write(ServerMsg{Type: "error", Message: "unknown message type"}); err != nil {
					return err
				}
			}
		case <-tick.C:
			if sub == nil {
				continue
			}
			up, rm := diff.Diff(query())
			if len(up) == 0 && len(rm) == 0 {
				continue
			}
			seq++
			now := time.Now().UTC()
			if err := write(ServerMsg{Type: "diff", Seq: seq, At: &now, Upsert: up, Remove: rm}); err != nil {
				return err
			}
		case <-status.C:
			if err := write(ServerMsg{Type: "status", Layers: s.Hub.Status()}); err != nil {
				return err
			}
		case <-ping.C:
			pctx, cancel := context.WithTimeout(ctx, 15*time.Second)
			err := c.Ping(pctx)
			cancel()
			if err != nil {
				return err
			}
		}
	}
}
