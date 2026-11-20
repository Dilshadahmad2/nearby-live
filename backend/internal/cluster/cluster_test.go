package cluster

import (
	"context"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/redis/go-redis/v9"

	"github.com/dilshadahmad2/nearby-live/backend/internal/delay"
	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
	"github.com/dilshadahmad2/nearby-live/backend/internal/live"
)

// Needs a real Redis: REDIS_TEST_URL=redis://localhost:6379/15 go test ./internal/cluster
func client(t *testing.T) *redis.Client {
	u := os.Getenv("REDIS_TEST_URL")
	if u == "" {
		t.Skip("REDIS_TEST_URL not set")
	}
	opt, err := redis.ParseURL(u)
	if err != nil {
		t.Fatal(err)
	}
	c := redis.NewClient(opt)
	if err := c.FlushDB(context.Background()).Err(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

type countRefresher struct {
	k live.Kind
	n atomic.Int32
}

func (c *countRefresher) Kind() live.Kind { return c.k }
func (c *countRefresher) EnsureFresh(context.Context, geo.Point, float64, time.Duration) {
	c.n.Add(1)
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for i := 0; i < 50; i++ {
		if cond() {
			return
		}
		time.Sleep(100 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func TestWorkerAndAPIShareTheHub(t *testing.T) {
	rc := client(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	wx := &countRefresher{k: live.KindWeather}
	workerDelays := delay.NewService(nil, nil, delay.Config{})
	worker := &Node{Role: RoleWorker, Redis: rc, Hub: live.NewHub(), Delays: workerDelays, ID: "worker",
		Refreshers: live.Refreshers{wx}}
	if err := worker.Start(ctx); err != nil {
		t.Fatal(err)
	}
	// A layer published before the API instance exists → loaded from the snapshot.
	worker.Hub.Replace(live.KindTrain, "timetable", []live.Object{{ID: "12951", Point: geo.Point{Lat: 28.65, Lon: 77.24}, FixTime: time.Now()}})
	time.Sleep(200 * time.Millisecond)

	apiDelays := delay.NewService(nil, nil, delay.Config{})
	api := &Node{Role: RoleAPI, Redis: rc, Hub: live.NewHub(), Delays: apiDelays, ID: "api"}
	if err := api.Start(ctx); err != nil {
		t.Fatal(err)
	}
	if got := api.Hub.All(live.KindTrain); len(got) != 1 {
		t.Fatalf("snapshot not loaded: %v", got)
	}
	time.Sleep(200 * time.Millisecond) // let subscriptions attach

	// Live changes replicate.
	worker.Hub.Upsert(live.KindFlight, "opensky", []live.Object{{ID: "abc", Point: geo.Point{Lat: 28.6, Lon: 77.2}, FixTime: time.Now(), DeadReckon: true, SpeedKmh: 700}}, time.Minute)
	eventually(t, "flight on the API instance", func() bool {
		o, ok := api.Hub.Get(live.KindFlight, "abc")
		return ok && o.DeadReckon
	})

	// Refresh requests reach the worker.
	rr := &RemoteRefresher{Node: api, K: live.KindWeather}
	rr.EnsureFresh(ctx, geo.Point{Lat: 28.65, Lon: 77.24}, 5, 0)
	rr.EnsureFresh(ctx, geo.Point{Lat: 28.65, Lon: 77.24}, 5, 0) // debounced
	eventually(t, "refresh on the worker", func() bool { return wx.n.Load() == 1 })
	time.Sleep(200 * time.Millisecond)
	if wx.n.Load() != 1 {
		t.Fatalf("refresh not debounced: %d", wx.n.Load())
	}

	// Delay pushes reach every instance.
	st := delay.Status{TrainNumber: "12951", JourneyDate: "2026-11-07", DelayMin: 25, Source: "push", ReportedAt: time.Now()}
	apiDelays.PutLocal(st)
	api.PublishDelay(ctx, st)
	eventually(t, "delay on the worker", func() bool { return workerDelays.DelayFor("12951") == 25*time.Minute })
}
