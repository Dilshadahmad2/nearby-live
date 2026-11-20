// Command seed (re)loads the Indian Railways stations, trains and timetable
// CSVs into PostgreSQL.
//
//	DATABASE_URL=postgres://… go run ./cmd/seed -data ./data
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"time"

	"github.com/dilshadahmad2/nearby-live/backend/internal/db"
	"github.com/dilshadahmad2/nearby-live/backend/internal/seed"
)

func main() {
	dir := flag.String("data", "data", "directory with stations.csv.gz, trains.csv.gz, train_stops.csv.gz")
	flag.Parse()
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		fmt.Fprintln(os.Stderr, "DATABASE_URL is required")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	pool, err := db.Open(ctx, url)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer pool.Close()
	if err := db.Migrate(ctx, pool); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	start := time.Now()
	res, err := seed.Run(ctx, pool, *dir)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Printf("loaded %d stations, %d trains, %d timetable stops in %s\n",
		res.Stations, res.Trains, res.Stops, time.Since(start).Round(time.Millisecond))
}
