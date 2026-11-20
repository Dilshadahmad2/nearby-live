package live

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	gtfs "github.com/MobilityData/gtfs-realtime-bindings/golang/gtfs"
	"google.golang.org/protobuf/proto"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// Transit kinds published by GTFS-Realtime feeds.
const (
	KindBus   Kind = "bus"
	KindMetro Kind = "metro"
)

// GTFSFeed is one GTFS-Realtime VehiclePositions feed (city buses, metro,
// …), polled on an interval and published as a full snapshot.
//
// Configure with GTFS_RT_FEEDS, one feed per line or separated by ";":
//
//	kind|name|url|Header: value
//
// e.g. "bus|delhi-otd|https://otd.delhi.gov.in/api/realtime/VehiclePositions.pb?key=KEY"
type GTFSFeed struct {
	Hub      *Hub
	Kind     Kind
	Name     string
	URL      string
	Headers  map[string]string
	Interval time.Duration // default 30 s
	Client   *http.Client
	Log      *slog.Logger
}

// ParseGTFSFeeds reads the GTFS_RT_FEEDS format.
func ParseGTFSFeeds(v string) ([]GTFSFeed, error) {
	var out []GTFSFeed
	for _, line := range strings.FieldsFunc(v, func(r rune) bool { return r == ';' || r == '\n' }) {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		parts := strings.Split(line, "|")
		if len(parts) < 3 {
			return nil, fmt.Errorf("GTFS_RT_FEEDS: want kind|name|url[|Header: value], got %q", line)
		}
		f := GTFSFeed{Kind: Kind(strings.TrimSpace(parts[0])), Name: strings.TrimSpace(parts[1]), URL: strings.TrimSpace(parts[2]), Headers: map[string]string{}}
		for _, h := range parts[3:] {
			if k, val, ok := strings.Cut(h, ":"); ok {
				f.Headers[strings.TrimSpace(k)] = strings.TrimSpace(val)
			}
		}
		if f.Kind == "" || !strings.HasPrefix(f.URL, "http") {
			return nil, fmt.Errorf("GTFS_RT_FEEDS: bad feed %q", line)
		}
		out = append(out, f)
	}
	return out, nil
}

// Run polls until ctx ends.
func (f *GTFSFeed) Run(ctx context.Context) {
	if f.Interval <= 0 {
		f.Interval = 30 * time.Second
	}
	if f.Client == nil {
		f.Client = &http.Client{Timeout: 25 * time.Second}
	}
	for {
		if err := f.poll(ctx); err != nil && ctx.Err() == nil {
			f.Hub.Fail(f.Kind, f.Name, err)
			if f.Log != nil {
				f.Log.Warn("gtfs-rt", "feed", f.Name, "err", err)
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(f.Interval):
		}
	}
}

func (f *GTFSFeed) poll(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, f.URL, nil)
	if err != nil {
		return err
	}
	for k, v := range f.Headers {
		req.Header.Set(k, v)
	}
	res, err := f.Client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode/100 != 2 {
		return fmt.Errorf("%s: HTTP %d", f.Name, res.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, 64<<20))
	if err != nil {
		return err
	}
	objs, err := ParseVehiclePositions(body, f.Kind, f.Name, time.Now())
	if err != nil {
		return err
	}
	f.Hub.Replace(f.Kind, f.Name, objs)
	return nil
}

// ParseVehiclePositions decodes a GTFS-Realtime FeedMessage into objects.
// Vehicles without a position, or with a fix older than 10 minutes, are
// skipped. Speed in the feed is m/s.
func ParseVehiclePositions(body []byte, kind Kind, source string, now time.Time) ([]Object, error) {
	var msg gtfs.FeedMessage
	if err := proto.Unmarshal(body, &msg); err != nil {
		return nil, fmt.Errorf("%s: not a GTFS-Realtime feed: %w", source, err)
	}
	headerTs := msg.GetHeader().GetTimestamp()
	out := make([]Object, 0, len(msg.GetEntity()))
	for _, e := range msg.GetEntity() {
		v := e.GetVehicle()
		if e.GetIsDeleted() || v == nil || v.GetPosition() == nil {
			continue
		}
		p := v.GetPosition()
		lat, lon := float64(p.GetLatitude()), float64(p.GetLongitude())
		if (lat == 0 && lon == 0) || lat < -90 || lat > 90 || lon < -180 || lon > 180 {
			continue
		}
		ts := v.GetTimestamp()
		if ts == 0 {
			ts = headerTs
		}
		fix := now
		if ts > 0 {
			fix = time.Unix(int64(ts), 0)
			if now.Sub(fix) > 10*time.Minute {
				continue
			}
		}
		id := v.GetVehicle().GetId()
		if id == "" {
			id = e.GetId()
		}
		label := v.GetVehicle().GetLabel()
		if label == "" {
			label = v.GetTrip().GetRouteId()
		}
		if label == "" {
			label = id
		}
		o := Object{
			ID:         source + ":" + id,
			Kind:       kind,
			Point:      geo.Point{Lat: lat, Lon: lon},
			HeadingDeg: float64(p.GetBearing()),
			SpeedKmh:   float64(p.GetSpeed()) * 3.6,
			Label:      label,
			Name:       v.GetTrip().GetRouteId(),
			Status:     strings.ToLower(v.GetCurrentStatus().String()),
			Source:     source,
			FixTime:    fix,
			DeadReckon: p.GetSpeed() > 0,
			Extra: map[string]any{
				"route_id": v.GetTrip().GetRouteId(),
				"trip_id":  v.GetTrip().GetTripId(),
				"stop_id":  v.GetStopId(),
				"plate":    v.GetVehicle().GetLicensePlate(),
			},
		}
		out = append(out, o)
	}
	return out, nil
}
