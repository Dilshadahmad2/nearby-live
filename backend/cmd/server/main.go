// Command server runs the Nearby Live backend API.
//
// Environment:
//
//	DATABASE_URL   postgres://user:pass@host:5432/db. When empty the server
//	               runs read-only from the CSVs in DATA_DIR (development).
//	PORT           listen port (default 8080)
//	DATA_DIR       directory with the seed CSVs (default ./data)
//	SEED_IF_EMPTY  load the CSVs when the stations table is empty (default true)
//	ADMIN_TOKEN    enables PUT /v1/admin/stations/{code} and POST /v1/admin/reload
//	LOG_LEVEL      debug | info (default info)
//
// Live data (see README "Live data"):
//
//	LIVE_TRAINS_INTERVAL    recompute all train positions (default 30s)
//	DELAY_PROVIDER_URL      live delay API URL template ({number}, {date}, {start_day}, …)
//	DELAY_PROVIDER_NAME     label for the source (default "http")
//	DELAY_PROVIDER_HEADERS  "Header: value; Other: value" (API keys go here)
//	DELAY_PATH              JSON path of the delay in minutes (e.g. data.delay)
//	DELAY_STATION_PATH, DELAY_LAT_PATH, DELAY_LON_PATH, DELAY_OK_PATH, DELAY_MESSAGE_PATH
//	DELAY_TTL               refetch after (default 3m)
//	DELAY_DAILY_LIMIT       provider requests per day (default 500)
//	LIVE_FLIGHTS            enable the OpenSky feed (default true)
//	OPENSKY_CLIENT_ID, OPENSKY_CLIENT_SECRET   OAuth2 client credentials (optional)
//	OPENSKY_DAILY_CREDITS   default 400 anonymous / 4000 with credentials
//	OPENSKY_SWEEP_INTERVAL  default: derived from the credit budget
//	OPENSKY_BBOX            south,west,north,east (default India)
//	WEATHER_MAX_AGE         Open-Meteo cache per ~11 km cell (default 10m)
//	TOMTOM_KEY              enables the traffic layer (key stays on the server)
//	TOMTOM_DAILY_REQUESTS   default 2000; TRAFFIC_MAX_AGE per ~5 km cell (default 3m)
//	TICKETMASTER_KEY        enables events (next 24 h around requests)
//	GTFS_RT_FEEDS           "kind|name|url|Header: value" per feed, ";"-separated (buses, metro)
//	GTFS_RT_INTERVAL        poll interval (default 30s)
//
// WebSocket stream (GET /v1/live/ws):
//
//	WS_MAX_CONNS            default 1000
//	WS_MIN_INTERVAL         fastest update interval a client may ask for (default 1s)
//	WS_ORIGINS              comma-separated browser origin patterns (default: any)
//
// Push alerts:
//
//	FCM_SERVICE_ACCOUNT_FILE  Firebase service-account JSON → push via FCM (Android + iOS)
//	ALERT_WEBHOOK_URL         also/instead POST every alert as JSON here
//	ALERT_INTERVAL            evaluation interval (default 30s); ALERT_COOLDOWN (default 1h)
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/alerts"
	"github.com/dilshadahmad2/nearby-live/backend/internal/api"
	"github.com/dilshadahmad2/nearby-live/backend/internal/db"
	"github.com/dilshadahmad2/nearby-live/backend/internal/delay"
	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
	"github.com/dilshadahmad2/nearby-live/backend/internal/live"
	"github.com/dilshadahmad2/nearby-live/backend/internal/rail"
	"github.com/dilshadahmad2/nearby-live/backend/internal/seed"
	"github.com/dilshadahmad2/nearby-live/backend/internal/stream"
)

func main() {
	level := slog.LevelInfo
	if os.Getenv("LOG_LEVEL") == "debug" {
		level = slog.LevelDebug
	}
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
	slog.SetDefault(log)
	if err := run(log); err != nil {
		log.Error("fatal", "err", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	url := os.Getenv("DATABASE_URL")
	if url == "" {
		log.Warn("DATABASE_URL not set: serving read-only from CSV files", "dir", env("DATA_DIR", "data"))
		ix, err := rail.LoadIndexFromCSV(env("DATA_DIR", "data"))
		if err != nil {
			return err
		}
		srv := api.New(ix)
		srv.Log = log
		if err := setupLive(ctx, log, srv, nil); err != nil {
			return err
		}
		if err := setupAlerts(ctx, log, srv, &alerts.MemStore{}); err != nil {
			return err
		}
		return serve(ctx, log, srv)
	}
	pool, err := db.Open(ctx, url)
	if err != nil {
		return err
	}
	defer pool.Close()
	if err := db.Migrate(ctx, pool); err != nil {
		return err
	}

	if env("SEED_IF_EMPTY", "true") == "true" {
		empty, err := seed.IsEmpty(ctx, pool)
		if err != nil {
			return err
		}
		if empty {
			log.Info("stations table empty, seeding", "dir", env("DATA_DIR", "data"))
			res, err := seed.Run(ctx, pool, env("DATA_DIR", "data"))
			if err != nil {
				return err
			}
			log.Info("seeded", "stations", res.Stations, "trains", res.Trains, "stops", res.Stops)
		}
	}

	store := &rail.Store{DB: pool}
	ix, err := store.LoadIndex(ctx)
	if err != nil {
		return err
	}
	st, loc, tr, stops := ix.Counts()
	log.Info("index loaded", "stations", st, "with_geo", loc, "trains", tr, "stops", stops)

	srv := api.New(ix)
	srv.Load = store.LoadIndex
	srv.Write = store.UpsertStation
	srv.AdminToken = os.Getenv("ADMIN_TOKEN")
	srv.Log = log
	if err := setupLive(ctx, log, srv, &delay.PgStore{DB: pool}); err != nil {
		return err
	}
	if err := setupAlerts(ctx, log, srv, &alerts.PgStore{DB: pool}); err != nil {
		return err
	}
	return serve(ctx, log, srv)
}

// setupLive configures live delays and starts the background feeds.
func setupLive(ctx context.Context, log *slog.Logger, srv *api.Server, store delay.Store) error {
	var provider delay.Provider
	if u := os.Getenv("DELAY_PROVIDER_URL"); u != "" {
		if os.Getenv("DELAY_PATH") == "" {
			return errors.New("DELAY_PATH is required with DELAY_PROVIDER_URL")
		}
		provider = &delay.HTTPProvider{
			ProviderName: env("DELAY_PROVIDER_NAME", "http"),
			URLTemplate:  u,
			Headers:      parseHeaders(os.Getenv("DELAY_PROVIDER_HEADERS")),
			DelayPath:    os.Getenv("DELAY_PATH"),
			StationPath:  os.Getenv("DELAY_STATION_PATH"),
			LatPath:      os.Getenv("DELAY_LAT_PATH"),
			LonPath:      os.Getenv("DELAY_LON_PATH"),
			OKPath:       os.Getenv("DELAY_OK_PATH"),
			MessagePath:  os.Getenv("DELAY_MESSAGE_PATH"),
		}
	}
	limit, _ := strconv.Atoi(env("DELAY_DAILY_LIMIT", "500"))
	srv.Delays = delay.NewService(provider, store, delay.Config{TTL: dur("DELAY_TTL", 3*time.Minute), DailyLimit: limit})
	if err := srv.Delays.Warm(ctx); err != nil {
		log.Warn("load recent delays", "err", err)
	}
	log.Info("live delays", "provider", srv.Delays.ProviderName(), "daily_limit", limit)

	trains := &live.TrainSource{Hub: srv.Hub, Index: srv.Index, Delays: srv.Delays,
		Interval: dur("LIVE_TRAINS_INTERVAL", 30*time.Second), Log: log}
	go trains.Run(ctx)

	if env("LIVE_FLIGHTS", "true") == "true" {
		credits, _ := strconv.Atoi(os.Getenv("OPENSKY_DAILY_CREDITS"))
		box := live.DefaultIndiaBBox
		if v := os.Getenv("OPENSKY_BBOX"); v != "" {
			b, err := parseBBox(v)
			if err != nil {
				return err
			}
			box = b
		}
		sky := &live.OpenSky{
			Hub:           srv.Hub,
			Coverage:      box,
			DailyCredits:  credits,
			SweepInterval: dur("OPENSKY_SWEEP_INTERVAL", 0),
			ClientID:      os.Getenv("OPENSKY_CLIENT_ID"),
			ClientSecret:  os.Getenv("OPENSKY_CLIENT_SECRET"),
			Log:           log,
		}
		srv.Sky = sky
		srv.Refreshers = append(srv.Refreshers, sky)
		go sky.Run(ctx)
	}

	// Weather (Open-Meteo, no key) is always on; traffic needs a TomTom key.
	srv.Refreshers = append(srv.Refreshers, &live.Weather{Hub: srv.Hub, MaxAge: dur("WEATHER_MAX_AGE", 10*time.Minute), Log: log})
	if key := os.Getenv("TOMTOM_KEY"); key != "" {
		reqs, _ := strconv.Atoi(os.Getenv("TOMTOM_DAILY_REQUESTS"))
		srv.Traffic = &live.Traffic{Hub: srv.Hub, Key: key, DailyRequests: reqs, MaxAge: dur("TRAFFIC_MAX_AGE", 3*time.Minute), Log: log}
		srv.Refreshers = append(srv.Refreshers, srv.Traffic)
	}
	if key := os.Getenv("TICKETMASTER_KEY"); key != "" {
		srv.Refreshers = append(srv.Refreshers, &live.Events{Hub: srv.Hub, Key: key, Log: log})
	}
	feeds, err := live.ParseGTFSFeeds(os.Getenv("GTFS_RT_FEEDS"))
	if err != nil {
		return err
	}
	for i := range feeds {
		f := feeds[i]
		f.Hub, f.Log, f.Interval = srv.Hub, log, dur("GTFS_RT_INTERVAL", 30*time.Second)
		go f.Run(ctx)
	}
	log.Info("live sources", "flights", srv.Sky != nil, "weather", true, "traffic", srv.Traffic != nil,
		"events", os.Getenv("TICKETMASTER_KEY") != "", "gtfs_rt_feeds", len(feeds))

	maxConns, _ := strconv.Atoi(os.Getenv("WS_MAX_CONNS"))
	var origins []string
	for _, o := range strings.Split(os.Getenv("WS_ORIGINS"), ",") {
		if o = strings.TrimSpace(o); o != "" {
			origins = append(origins, o)
		}
	}
	srv.Stream = &stream.Server{Hub: srv.Hub, Refreshers: srv.Refreshers, Log: log, Cfg: stream.Config{
		MaxConns:       maxConns,
		MinInterval:    dur("WS_MIN_INTERVAL", time.Second),
		OriginPatterns: origins,
	}}
	return nil
}

// setupAlerts picks the push channel(s) and starts the alert worker.
func setupAlerts(ctx context.Context, log *slog.Logger, srv *api.Server, store alerts.Store) error {
	srv.Alerts = store
	var notifiers alerts.Multi
	if f := os.Getenv("FCM_SERVICE_ACCOUNT_FILE"); f != "" {
		fcm, err := alerts.NewFCMFromFile(ctx, f)
		if err != nil {
			return err
		}
		notifiers = append(notifiers, fcm)
	}
	if u := os.Getenv("ALERT_WEBHOOK_URL"); u != "" {
		notifiers = append(notifiers, &alerts.Webhook{URL: u})
	}
	var n alerts.Notifier = notifiers
	if len(notifiers) == 0 {
		n = alerts.LogNotifier{Log: log}
	}
	w := &alerts.Worker{Hub: srv.Hub, Store: store, Notifier: n, Log: log,
		Interval: dur("ALERT_INTERVAL", 30*time.Second), Cooldown: dur("ALERT_COOLDOWN", time.Hour)}
	go w.Run(ctx)
	log.Info("alerts", "fcm", os.Getenv("FCM_SERVICE_ACCOUNT_FILE") != "", "webhook", os.Getenv("ALERT_WEBHOOK_URL") != "")
	return nil
}

func parseHeaders(v string) map[string]string {
	out := map[string]string{}
	for _, part := range strings.Split(v, ";") {
		k, val, ok := strings.Cut(part, ":")
		if ok && strings.TrimSpace(k) != "" {
			out[strings.TrimSpace(k)] = strings.TrimSpace(val)
		}
	}
	return out
}

func parseBBox(v string) (geo.BBox, error) {
	parts := strings.Split(v, ",")
	if len(parts) != 4 {
		return geo.BBox{}, errors.New("OPENSKY_BBOX must be south,west,north,east")
	}
	var f [4]float64
	for i, p := range parts {
		x, err := strconv.ParseFloat(strings.TrimSpace(p), 64)
		if err != nil {
			return geo.BBox{}, errors.New("OPENSKY_BBOX must be south,west,north,east")
		}
		f[i] = x
	}
	return geo.BBox{South: f[0], West: f[1], North: f[2], East: f[3]}, nil
}

func dur(k string, def time.Duration) time.Duration {
	if v := os.Getenv(k); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return def
}

func serve(ctx context.Context, log *slog.Logger, srv *api.Server) error {
	httpSrv := &http.Server{
		Addr:              ":" + env("PORT", "8080"),
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	errc := make(chan error, 1)
	go func() {
		log.Info("listening", "addr", httpSrv.Addr)
		errc <- httpSrv.ListenAndServe()
	}()
	select {
	case err := <-errc:
		if !errors.Is(err, http.ErrServerClosed) {
			return err
		}
	case <-ctx.Done():
		log.Info("shutting down")
		shut, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return httpSrv.Shutdown(shut)
	}
	return nil
}

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}
