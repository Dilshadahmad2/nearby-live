// Package stream serves the live hub over WebSocket: a client subscribes
// to an area and receives a snapshot, then only changes (moved, entered,
// left) at a fixed interval.
//
// # Protocol (JSON text frames)
//
// Client → server:
//
//	{"type":"subscribe","lat":28.65,"lon":77.24,"radius_km":10,"types":["train","flight","traffic","weather"],"limit":200,"interval_ms":2000}
//	{"type":"ping"}
//
// Sending "subscribe" again (user moved, range changed) replaces the
// subscription and yields a fresh snapshot.
//
// Server → client:
//
//	{"type":"hello","protocol":1,"min_interval_ms":1000}
//	{"type":"snapshot","seq":1,"at":"…","items":[Result…],"layers":[…]}
//	{"type":"diff","seq":2,"at":"…","upsert":[Result…],"remove":[{"kind":"flight","id":"800c1b"}]}
//	{"type":"status","layers":[…]}       // every 30 s
//	{"type":"pong"}
//	{"type":"error","message":"…"}
//
// seq increases by one per snapshot/diff; a gap means a message was lost
// and the client should re-subscribe.
package stream

import (
	"encoding/json"
	"math"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/live"
)

// ProtocolVersion is sent in "hello".
const ProtocolVersion = 1

// ClientMsg is any message from the client.
type ClientMsg struct {
	Type       string   `json:"type"`
	Lat        *float64 `json:"lat"`
	Lon        *float64 `json:"lon"`
	RadiusKm   float64  `json:"radius_km"`
	Types      []string `json:"types"`
	Limit      int      `json:"limit"`
	IntervalMs int      `json:"interval_ms"`
}

// Ref names a removed object.
type Ref struct {
	Kind live.Kind `json:"kind"`
	ID   string    `json:"id"`
}

// ServerMsg is any message to the client.
type ServerMsg struct {
	Type          string             `json:"type"`
	Seq           uint64             `json:"seq,omitempty"`
	At            *time.Time         `json:"at,omitempty"`
	Items         []live.Result      `json:"items,omitempty"`
	Upsert        []live.Result      `json:"upsert,omitempty"`
	Remove        []Ref              `json:"remove,omitempty"`
	Layers        []live.LayerStatus `json:"layers,omitempty"`
	Message       string             `json:"message,omitempty"`
	Protocol      int                `json:"protocol,omitempty"`
	MinIntervalMs int                `json:"min_interval_ms,omitempty"`
}

// fingerprint captures what a client can see of an object; a change in any
// field means the object is re-sent.
type fingerprint struct {
	lat, lon       int64 // 1e-5° ≈ 1 m
	heading, speed int32
	alt            int32
	status         string
	delay          int32
	hasDelay       bool
	label, name    string
	prev, next     string
	source         string
	onGround       bool
	extra          string // weather values, traffic speeds, …
}

func fp(r live.Result) fingerprint {
	f := fingerprint{
		lat:      int64(math.Round(r.Point.Lat * 1e5)),
		lon:      int64(math.Round(r.Point.Lon * 1e5)),
		heading:  int32(math.Round(r.HeadingDeg)),
		speed:    int32(math.Round(r.SpeedKmh)),
		status:   r.Status,
		label:    r.Label,
		name:     r.Name,
		prev:     r.PrevStop,
		next:     r.NextStop,
		source:   r.Source,
		onGround: r.OnGround,
	}
	if r.AltitudeM != nil {
		f.alt = int32(math.Round(*r.AltitudeM / 10))
	}
	if r.DelayMin != nil {
		f.delay, f.hasDelay = int32(*r.DelayMin), true
	}
	if len(r.Extra) > 0 {
		b, _ := json.Marshal(r.Extra) // map keys are sorted, so this is stable
		f.extra = string(b)
	}
	return f
}

// Differ tracks what one client has been sent.
type Differ struct {
	sent map[Ref]fingerprint
}

// NewDiffer starts empty.
func NewDiffer() *Differ { return &Differ{sent: map[Ref]fingerprint{}} }

// Reset forgets everything (before a snapshot).
func (d *Differ) Reset() { d.sent = map[Ref]fingerprint{} }

// Snapshot records all of cur as sent.
func (d *Differ) Snapshot(cur []live.Result) {
	d.Reset()
	for _, r := range cur {
		d.sent[Ref{r.Kind, r.ID}] = fp(r)
	}
}

// Diff returns the objects that are new or changed since the last call and
// the ones that are gone, and records cur as sent.
func (d *Differ) Diff(cur []live.Result) (upsert []live.Result, remove []Ref) {
	seen := make(map[Ref]bool, len(cur))
	for _, r := range cur {
		k := Ref{r.Kind, r.ID}
		seen[k] = true
		f := fp(r)
		if old, ok := d.sent[k]; !ok || old != f {
			upsert = append(upsert, r)
			d.sent[k] = f
		}
	}
	for k := range d.sent {
		if !seen[k] {
			remove = append(remove, k)
			delete(d.sent, k)
		}
	}
	return upsert, remove
}
