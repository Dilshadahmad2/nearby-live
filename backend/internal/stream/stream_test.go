package stream

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
	"github.com/dilshadahmad2/nearby-live/backend/internal/live"
)

func res(kind live.Kind, id string, lat, lon float64) live.Result {
	return live.Result{Object: live.Object{ID: id, Kind: kind, Point: geo.Point{Lat: lat, Lon: lon}}}
}

func TestDiffer(t *testing.T) {
	d := NewDiffer()
	d.Snapshot([]live.Result{res("train", "a", 28, 77), res("flight", "f", 28.1, 77)})

	// Unchanged → nothing; sub-metre jitter is ignored.
	up, rm := d.Diff([]live.Result{res("train", "a", 28.000001, 77), res("flight", "f", 28.1, 77)})
	if len(up) != 0 || len(rm) != 0 {
		t.Fatalf("no-op diff: %v %v", up, rm)
	}
	// a moved, f left, b entered.
	up, rm = d.Diff([]live.Result{res("train", "a", 28.01, 77), res("train", "b", 28.2, 77)})
	if len(up) != 2 || len(rm) != 1 || rm[0] != (Ref{"flight", "f"}) {
		t.Fatalf("diff: %v %v", up, rm)
	}
	// A delay change alone is sent.
	late := res("train", "a", 28.01, 77)
	m := 15
	late.DelayMin = &m
	up, _ = d.Diff([]live.Result{late, res("train", "b", 28.2, 77)})
	if len(up) != 1 || up[0].ID != "a" {
		t.Fatalf("delay change: %v", up)
	}
}

type client struct {
	t *testing.T
	c *websocket.Conn
}

func dial(t *testing.T, url string) *client {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, strings.Replace(url, "http", "ws", 1), nil)
	if err != nil {
		t.Fatal(err)
	}
	cl := &client{t, c}
	if m := cl.read(); m.Type != "hello" || m.Protocol != ProtocolVersion {
		t.Fatalf("hello: %+v", m)
	}
	return cl
}

func (cl *client) send(v any) {
	b, _ := json.Marshal(v)
	if err := cl.c.Write(context.Background(), websocket.MessageText, b); err != nil {
		cl.t.Fatal(err)
	}
}

func (cl *client) read() ServerMsg {
	cl.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, b, err := cl.c.Read(ctx)
	if err != nil {
		cl.t.Fatalf("read: %v", err)
	}
	var m ServerMsg
	if err := json.Unmarshal(b, &m); err != nil {
		cl.t.Fatal(err)
	}
	return m
}

// readType skips status/pong frames.
func (cl *client) readType(want string) ServerMsg {
	cl.t.Helper()
	for i := 0; i < 10; i++ {
		if m := cl.read(); m.Type == want {
			return m
		} else if m.Type == "error" {
			cl.t.Fatalf("error: %s", m.Message)
		}
	}
	cl.t.Fatalf("no %s message", want)
	return ServerMsg{}
}

func TestStreamSnapshotAndDiffs(t *testing.T) {
	hub := live.NewHub()
	hub.Replace(live.KindTrain, "test", []live.Object{
		{ID: "near", Point: geo.Point{Lat: 28.65, Lon: 77.24}, FixTime: time.Now()},
		{ID: "far", Point: geo.Point{Lat: 19.07, Lon: 72.87}, FixTime: time.Now()},
	})
	srv := &Server{Hub: hub, Cfg: Config{MinInterval: 50 * time.Millisecond, DefaultInterval: 50 * time.Millisecond}}
	ts := httptest.NewServer(srv)
	defer ts.Close()

	cl := dial(t, ts.URL)
	defer cl.c.CloseNow()

	cl.send(map[string]any{"type": "subscribe", "lat": 28.65, "lon": 77.24, "radius_km": 10, "types": []string{"trains"}, "interval_ms": 50})
	snap := cl.readType("snapshot")
	if snap.Seq != 1 || len(snap.Items) != 1 || snap.Items[0].ID != "near" || snap.Items[0].DistanceKm == nil {
		t.Fatalf("snapshot: %+v", snap)
	}

	// "near" moves, "new" enters.
	hub.Replace(live.KindTrain, "test", []live.Object{
		{ID: "near", Point: geo.Point{Lat: 28.66, Lon: 77.24}, FixTime: time.Now()},
		{ID: "new", Point: geo.Point{Lat: 28.62, Lon: 77.2}, FixTime: time.Now()},
	})
	d := cl.readType("diff")
	if d.Seq != 2 || len(d.Upsert) != 2 || len(d.Remove) != 0 {
		t.Fatalf("diff 1: %+v", d)
	}

	// "near" leaves the area.
	hub.Replace(live.KindTrain, "test", []live.Object{{ID: "new", Point: geo.Point{Lat: 28.62, Lon: 77.2}, FixTime: time.Now()}})
	d = cl.readType("diff")
	if d.Seq != 3 || len(d.Upsert) != 0 || len(d.Remove) != 1 || d.Remove[0].ID != "near" {
		t.Fatalf("diff 2: %+v", d)
	}

	// Re-subscribe somewhere else → fresh snapshot.
	cl.send(map[string]any{"type": "subscribe", "lat": 19.07, "lon": 72.87, "radius_km": 5})
	snap = cl.readType("snapshot")
	if len(snap.Items) != 0 || snap.Seq != 4 {
		t.Fatalf("re-subscribe: %+v", snap)
	}

	cl.send(map[string]any{"type": "ping"})
	cl.readType("pong")

	cl.send(map[string]any{"type": "subscribe"})
	if m := cl.read(); m.Type != "error" {
		t.Fatalf("bad subscribe: %+v", m)
	}
}

func TestStreamConnectionLimit(t *testing.T) {
	srv := &Server{Hub: live.NewHub(), Cfg: Config{MaxConns: 1}}
	ts := httptest.NewServer(srv)
	defer ts.Close()
	cl := dial(t, ts.URL)
	defer cl.c.CloseNow()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, resp, err := websocket.Dial(ctx, strings.Replace(ts.URL, "http", "ws", 1), nil)
	if err == nil || resp == nil || resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("second connection: err=%v resp=%v", err, resp)
	}
}
