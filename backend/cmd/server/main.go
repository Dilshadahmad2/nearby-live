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
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/api"
	"github.com/dilshadahmad2/nearby-live/backend/internal/db"
	"github.com/dilshadahmad2/nearby-live/backend/internal/rail"
	"github.com/dilshadahmad2/nearby-live/backend/internal/seed"
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
	return serve(ctx, log, srv)
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
