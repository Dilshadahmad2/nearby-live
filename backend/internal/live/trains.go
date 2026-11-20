package live

import (
	"context"
	"log/slog"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/delay"
	"github.com/dilshadahmad2/nearby-live/backend/internal/rail"
)

// TrainSource recomputes the position of every Indian train from its
// timetable, live delay and (when a provider reports one) live coordinates,
// and publishes them to the hub.
type TrainSource struct {
	Hub      *Hub
	Index    func() *rail.Index
	Delays   *delay.Service // may be nil
	Interval time.Duration
	Log      *slog.Logger
	Now      func() time.Time
}

// LiveFixMaxAge: provider coordinates younger than this replace the
// timetable estimate.
const LiveFixMaxAge = 10 * time.Minute

// Run publishes immediately and then every Interval until ctx ends.
func (s *TrainSource) Run(ctx context.Context) {
	if s.Interval <= 0 {
		s.Interval = 30 * time.Second
	}
	t := time.NewTicker(s.Interval)
	defer t.Stop()
	for {
		start := time.Now()
		objs := s.Snapshot()
		s.Hub.Replace(KindTrain, "timetable", objs)
		if s.Log != nil {
			s.Log.Debug("trains published", "count", len(objs), "took", time.Since(start))
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Snapshot computes all running trains now.
func (s *TrainSource) Snapshot() []Object {
	now := time.Now()
	if s.Now != nil {
		now = s.Now()
	}
	ix := s.Index()
	var out []Object
	for _, num := range ix.TrainNumbers() {
		o, ok := TrainObject(ix, s.Delays, num, now)
		if ok {
			out = append(out, o)
		}
	}
	return out
}

// TrainObject builds the live object for one train, or false when it is
// not on the line.
func TrainObject(ix *rail.Index, delays *delay.Service, num string, now time.Time) (Object, bool) {
	var d time.Duration
	var st delay.Status
	var haveLive bool
	if delays != nil {
		st, haveLive = delays.Latest(num)
		if haveLive {
			d = time.Duration(st.DelayMin) * time.Minute
		}
	}
	pos, ok := ix.TrainPosition(num, now, d)
	if !ok || (pos.Status != rail.StatusRunning && pos.Status != rail.StatusAtStation) {
		return Object{}, false
	}
	o := Object{
		ID:         num,
		Label:      num,
		HeadingDeg: pos.BearingDeg,
		SpeedKmh:   pos.SpeedKmh,
		Status:     string(pos.Status),
		Source:     "timetable",
		Estimated:  true,
		FixTime:    now,
	}
	if t := ix.Train(num); t != nil {
		o.Name = t.Name
		o.Extra = map[string]any{"from": t.FromCode, "to": t.ToCode, "type": t.Type}
	}
	if pos.Prev != nil {
		o.PrevStop = pos.Prev.Code
	}
	if pos.Next != nil {
		o.NextStop = pos.Next.Code
	}
	if haveLive {
		dm := st.DelayMin
		o.DelayMin = &dm
		o.Source = "timetable+" + st.Source
		if st.Point != nil && now.Sub(st.ReportedAt) < LiveFixMaxAge {
			o.Point = *st.Point
			o.Source = st.Source
			o.FixTime = st.ReportedAt
			return o, true
		}
	}
	if pos.Point == nil {
		return Object{}, false
	}
	o.Point = *pos.Point
	return o, true
}
