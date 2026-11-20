package live

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	gtfs "github.com/MobilityData/gtfs-realtime-bindings/golang/gtfs"
	"google.golang.org/protobuf/proto"
)

func vehicleFeed(t *testing.T, now time.Time) []byte {
	t.Helper()
	ts := uint64(now.Unix())
	old := uint64(now.Add(-time.Hour).Unix())
	f32 := func(v float32) *float32 { return &v }
	msg := &gtfs.FeedMessage{
		Header: &gtfs.FeedHeader{GtfsRealtimeVersion: proto.String("2.0"), Timestamp: &ts},
		Entity: []*gtfs.FeedEntity{
			{Id: proto.String("e1"), Vehicle: &gtfs.VehiclePosition{
				Vehicle:   &gtfs.VehicleDescriptor{Id: proto.String("DL1PC1234"), Label: proto.String("534")},
				Trip:      &gtfs.TripDescriptor{RouteId: proto.String("534UP"), TripId: proto.String("t1")},
				Position:  &gtfs.Position{Latitude: f32(28.65), Longitude: f32(77.24), Bearing: f32(90), Speed: f32(10)},
				Timestamp: &ts,
			}},
			{Id: proto.String("stale"), Vehicle: &gtfs.VehiclePosition{
				Position: &gtfs.Position{Latitude: f32(28.6), Longitude: f32(77.2)}, Timestamp: &old}},
			{Id: proto.String("nopos"), Vehicle: &gtfs.VehiclePosition{}},
		},
	}
	b, err := proto.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestParseVehiclePositions(t *testing.T) {
	now := time.Now()
	objs, err := ParseVehiclePositions(vehicleFeed(t, now), KindBus, "delhi", now)
	if err != nil || len(objs) != 1 {
		t.Fatalf("objs=%+v err=%v", objs, err)
	}
	o := objs[0]
	if o.ID != "delhi:DL1PC1234" || o.Label != "534" || o.Name != "534UP" || o.SpeedKmh != 36 || o.HeadingDeg != 90 || !o.DeadReckon {
		t.Fatalf("bus = %+v", o)
	}
	if _, err := ParseVehiclePositions([]byte("not protobuf"), KindBus, "x", now); err == nil {
		t.Fatal("garbage should fail")
	}
}

func TestGTFSFeedPollsIntoHub(t *testing.T) {
	now := time.Now()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-Key") != "k" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		w.Write(vehicleFeed(t, now))
	}))
	defer srv.Close()
	feeds, err := ParseGTFSFeeds("bus|delhi|" + srv.URL + "|X-Key: k")
	if err != nil || len(feeds) != 1 {
		t.Fatalf("feeds=%v err=%v", feeds, err)
	}
	h := NewHub()
	f := feeds[0]
	f.Hub, f.Client = h, srv.Client()
	if err := f.poll(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := h.Find(Query{BBox: &DefaultIndiaBBox, Kinds: []Kind{KindBus}}); len(got) != 1 {
		t.Fatalf("hub buses = %d", len(got))
	}
	if _, err := ParseGTFSFeeds("nonsense"); err == nil {
		t.Fatal("bad config should fail")
	}
}

func TestParseTicketmaster(t *testing.T) {
	body := []byte(`{"_embedded": {"events": [
	  {"id": "Z1", "name": "Music Fest 2026", "url": "https://tm/e/Z1",
	   "dates": {"start": {"localDate": "2026-11-07", "localTime": "17:00:00", "dateTime": "2026-11-07T11:30:00Z"}},
	   "classifications": [{"segment": {"name": "Music"}}],
	   "_embedded": {"venues": [{"name": "JLN Stadium", "location": {"latitude": "28.5828", "longitude": "77.2344"}}]}},
	  {"id": "Z2", "name": "No venue", "_embedded": {"venues": []}}
	]}}`)
	objs, err := ParseTicketmaster(body, time.Now())
	if err != nil || len(objs) != 1 {
		t.Fatalf("objs=%+v err=%v", objs, err)
	}
	o := objs[0]
	if o.ID != "tm:Z1" || o.Label != "Music Fest 2026" || o.Name != "JLN Stadium" || o.Point.Lat != 28.5828 ||
		o.Extra["local_time"] != "17:00:00" || o.Extra["category"] != "Music" {
		t.Fatalf("event = %+v", o)
	}
	if objs, _ := ParseTicketmaster([]byte(`{}`), time.Now()); len(objs) != 0 {
		t.Fatal("empty response")
	}
}
