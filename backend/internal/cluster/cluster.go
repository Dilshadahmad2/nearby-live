// Package cluster lets several backend instances share one live hub
// through Redis.
//
// Roles (ROLE env):
//
//   - all (default): a single instance runs feeds and serves requests.
//   - worker: runs every feed (trains, OpenSky, weather, traffic, events,
//     GTFS-RT, alerts) — so all upstream calls and budgets live in one place
//     — and publishes every layer change.
//   - api: serves REST and WebSocket only. It mirrors the worker's layers,
//     forwards "refresh this area" requests to the worker, and broadcasts
//     delay pushes to every instance.
//
// Channels: nearby:layer (changes), nearby:refresh (area requests),
// nearby:delay (delay reports). The last full snapshot of every layer is
// kept in nearby:snapshot:<kind> so a new API instance starts warm.
package cluster

import (
	"context"
	"encoding/json"
	"log/slog"
	"math"
	"sync"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/dilshadahmad2/nearby-live/backend/internal/delay"
	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
	"github.com/dilshadahmad2/nearby-live/backend/internal/live"
)

const (
	chLayer   = "nearby:layer"
	chRefresh = "nearby:refresh"
	chDelay   = "nearby:delay"
	keySnap   = "nearby:snapshot:"
)

// Role of an instance.
type Role string

const (
	RoleAll    Role = "all"
	RoleWorker Role = "worker"
	RoleAPI    Role = "api"
)

// Node connects one instance to the cluster.
type Node struct {
	Role   Role
	Redis  *redis.Client
	Hub    *live.Hub
	Delays *delay.Service
	// Refreshers run on the worker for requests from API instances.
	Refreshers live.Refreshers
	Log        *slog.Logger
	ID         string // instance id, to ignore our own messages
}

type refreshReq struct {
	From     string      `json:"from"`
	Kinds    []live.Kind `json:"kinds"`
	Point    geo.Point   `json:"point"`
	RadiusKm float64     `json:"radius_km"`
}

type delayMsg struct {
	From   string       `json:"from"`
	Status delay.Status `json:"status"`
}

type layerMsg struct {
	From   string      `json:"from"`
	Change live.Change `json:"change"`
}

// Start wires the hub to Redis for the node's role and runs until ctx ends.
func (n *Node) Start(ctx context.Context) error {
	if err := n.Redis.Ping(ctx).Err(); err != nil {
		return err
	}
	switch n.Role {
	case RoleWorker:
		n.Hub.OnChange = func(c live.Change) { n.publishLayer(ctx, c) }
		go n.listen(ctx, chRefresh, n.onRefresh)
		go n.listen(ctx, chDelay, n.onDelay)
	case RoleAPI:
		n.loadSnapshots(ctx)
		go n.listen(ctx, chLayer, n.onLayer)
		go n.listen(ctx, chDelay, n.onDelay)
	}
	return nil
}

// ---------------------------------------------------------------- worker

func (n *Node) publishLayer(ctx context.Context, c live.Change) {
	b, err := json.Marshal(layerMsg{From: n.ID, Change: c})
	if err != nil {
		return
	}
	pipe := n.Redis.Pipeline()
	pipe.Publish(ctx, chLayer, b)
	if c.Op == "replace" {
		pipe.Set(ctx, keySnap+string(c.Kind), b, 10*time.Minute)
	} else {
		// Keep a rolling snapshot of upsert layers for new instances.
		snap := live.Change{Kind: c.Kind, Source: c.Source, Op: "upsert", Expire: c.Expire,
			Objects: n.Hub.All(c.Kind)}
		if sb, err := json.Marshal(layerMsg{From: n.ID, Change: snap}); err == nil {
			pipe.Set(ctx, keySnap+string(c.Kind), sb, 10*time.Minute)
		}
	}
	if _, err := pipe.Exec(ctx); err != nil && ctx.Err() == nil {
		n.log().Warn("cluster: publish layer", "kind", c.Kind, "err", err)
	}
}

func (n *Node) onRefresh(payload string) {
	var r refreshReq
	if json.Unmarshal([]byte(payload), &r) != nil || r.From == n.ID {
		return
	}
	n.Refreshers.Ensure(context.Background(), r.Kinds, r.Point, r.RadiusKm, 0)
}

// ------------------------------------------------------------------- api

func (n *Node) loadSnapshots(ctx context.Context) {
	keys, err := n.Redis.Keys(ctx, keySnap+"*").Result()
	if err != nil {
		n.log().Warn("cluster: list snapshots", "err", err)
		return
	}
	for _, k := range keys {
		if b, err := n.Redis.Get(ctx, k).Bytes(); err == nil {
			n.onLayer(string(b))
		}
	}
	n.log().Info("cluster: loaded snapshots", "layers", len(keys))
}

func (n *Node) onLayer(payload string) {
	var m layerMsg
	if json.Unmarshal([]byte(payload), &m) != nil || m.From == n.ID {
		return
	}
	n.Hub.ApplyRemote(m.Change)
}

// RemoteRefresher forwards area refreshes from an API instance to the
// worker (debounced per area so a busy instance doesn't flood Redis).
type RemoteRefresher struct {
	Node *Node
	K    live.Kind

	mu   sync.Mutex
	last map[[2]int]time.Time
}

// Kind implements live.Refresher.
func (r *RemoteRefresher) Kind() live.Kind { return r.K }

// EnsureFresh implements live.Refresher. It never waits: the worker's
// result arrives as a layer change and reaches streams in the next diff.
func (r *RemoteRefresher) EnsureFresh(ctx context.Context, p geo.Point, radiusKm float64, _ time.Duration) {
	cell := [2]int{int(math.Floor(p.Lat * 10)), int(math.Floor(p.Lon * 10))}
	r.mu.Lock()
	if r.last == nil {
		r.last = map[[2]int]time.Time{}
	}
	if time.Since(r.last[cell]) < 15*time.Second {
		r.mu.Unlock()
		return
	}
	r.last[cell] = time.Now()
	r.mu.Unlock()
	b, _ := json.Marshal(refreshReq{From: r.Node.ID, Kinds: []live.Kind{r.K}, Point: p, RadiusKm: radiusKm})
	if err := r.Node.Redis.Publish(ctx, chRefresh, b).Err(); err != nil {
		r.Node.log().Debug("cluster: publish refresh", "err", err)
	}
}

// ---------------------------------------------------------------- shared

// PublishDelay broadcasts a delay report so every instance applies it.
func (n *Node) PublishDelay(ctx context.Context, st delay.Status) {
	b, _ := json.Marshal(delayMsg{From: n.ID, Status: st})
	if err := n.Redis.Publish(ctx, chDelay, b).Err(); err != nil {
		n.log().Warn("cluster: publish delay", "err", err)
	}
}

func (n *Node) onDelay(payload string) {
	var m delayMsg
	if json.Unmarshal([]byte(payload), &m) != nil || m.From == n.ID || n.Delays == nil {
		return
	}
	n.Delays.PutLocal(m.Status)
}

func (n *Node) listen(ctx context.Context, channel string, fn func(string)) {
	for ctx.Err() == nil {
		sub := n.Redis.Subscribe(ctx, channel)
		ch := sub.Channel()
		for msg := range ch {
			fn(msg.Payload)
		}
		_ = sub.Close()
		select {
		case <-ctx.Done():
		case <-time.After(2 * time.Second): // reconnect
		}
	}
}

func (n *Node) log() *slog.Logger {
	if n.Log != nil {
		return n.Log
	}
	return slog.Default()
}
