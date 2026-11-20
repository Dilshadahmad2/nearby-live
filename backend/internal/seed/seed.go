// Package seed loads the bundled Indian Railways CSVs (data/*.csv.gz,
// converted from datameet/railways, CC0) into PostgreSQL.
package seed

import (
	"compress/gzip"
	"context"
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Result counts the rows loaded.
type Result struct {
	Stations, Trains, Stops int64
}

// IsEmpty reports whether the stations table has no rows.
func IsEmpty(ctx context.Context, db *pgxpool.Pool) (bool, error) {
	var n int64
	err := db.QueryRow(ctx, `SELECT count(*) FROM stations`).Scan(&n)
	return n == 0, err
}

// Run replaces the contents of stations, trains and train_stops with the
// CSVs in dir, in one transaction. Station rows edited through the admin
// API are overwritten only when the CSV has the same code.
func Run(ctx context.Context, db *pgxpool.Pool, dir string) (Result, error) {
	var res Result
	tx, err := db.Begin(ctx)
	if err != nil {
		return res, err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // no-op after commit

	if _, err := tx.Exec(ctx, `
		CREATE TEMP TABLE stations_in (code TEXT, name TEXT, state TEXT, zone TEXT, address TEXT, lat DOUBLE PRECISION, lon DOUBLE PRECISION) ON COMMIT DROP;
		CREATE TEMP TABLE trains_in (number TEXT, name TEXT, type TEXT, zone TEXT, from_code TEXT, to_code TEXT,
			departure TEXT, arrival TEXT, duration_min INTEGER, distance_km INTEGER, return_train TEXT) ON COMMIT DROP;
		CREATE TEMP TABLE stops_in (train_number TEXT, seq INTEGER, station_code TEXT, day INTEGER, arrival_min INTEGER, departure_min INTEGER) ON COMMIT DROP;
	`); err != nil {
		return res, err
	}

	if res.Stations, err = copyCSV(ctx, tx, filepath.Join(dir, "stations.csv.gz"), "stations_in",
		[]string{"code", "name", "state", "zone", "address", "lat", "lon"},
		[]kind{text, text, text, text, text, float, float}); err != nil {
		return res, err
	}
	if res.Trains, err = copyCSV(ctx, tx, filepath.Join(dir, "trains.csv.gz"), "trains_in",
		[]string{"number", "name", "type", "zone", "from_code", "to_code", "departure", "arrival", "duration_min", "distance_km", "return_train"},
		[]kind{text, text, text, text, text, text, text, text, integer, integer, text}); err != nil {
		return res, err
	}
	if res.Stops, err = copyCSV(ctx, tx, filepath.Join(dir, "train_stops.csv.gz"), "stops_in",
		[]string{"train_number", "seq", "station_code", "day", "arrival_min", "departure_min"},
		[]kind{text, integer, text, integer, integer, integer}); err != nil {
		return res, err
	}

	if _, err := tx.Exec(ctx, `
		INSERT INTO stations (code, name, state, zone, address, lat, lon)
		SELECT code, name, COALESCE(state, ''), COALESCE(zone, ''), COALESCE(address, ''), lat, lon FROM stations_in
		ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, state = EXCLUDED.state, zone = EXCLUDED.zone,
			address = EXCLUDED.address,
			-- keep coordinates someone added by hand when the source has none
			lat = COALESCE(EXCLUDED.lat, stations.lat), lon = COALESCE(EXCLUDED.lon, stations.lon),
			updated_at = now();

		DELETE FROM train_stops;
		DELETE FROM trains;
		INSERT INTO trains SELECT number, name, COALESCE(type, ''), COALESCE(zone, ''), COALESCE(from_code, ''),
			COALESCE(to_code, ''), COALESCE(departure, ''), COALESCE(arrival, ''), duration_min, distance_km,
			COALESCE(return_train, '') FROM trains_in;
		INSERT INTO train_stops SELECT s.* FROM stops_in s JOIN trains t ON t.number = s.train_number;
	`); err != nil {
		return res, fmt.Errorf("upsert: %w", err)
	}
	return res, tx.Commit(ctx)
}

type kind int

const (
	text kind = iota
	integer
	float
)

// copyCSV streams a gzipped CSV (with header) into table via COPY.
func copyCSV(ctx context.Context, tx pgx.Tx, path, table string, cols []string, kinds []kind) (int64, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return 0, fmt.Errorf("%s: %w", path, err)
	}
	r := csv.NewReader(gz)
	r.ReuseRecord = true
	if _, err := r.Read(); err != nil { // header
		return 0, fmt.Errorf("%s: %w", path, err)
	}
	src := &csvSource{r: r, kinds: kinds, path: path}
	n, err := tx.CopyFrom(ctx, pgx.Identifier{table}, cols, src)
	if err != nil {
		return n, fmt.Errorf("copy %s: %w", path, err)
	}
	return n, nil
}

type csvSource struct {
	r     *csv.Reader
	kinds []kind
	path  string
	row   []any
	err   error
	line  int
}

func (s *csvSource) Next() bool {
	rec, err := s.r.Read()
	if err == io.EOF {
		return false
	}
	s.line++
	if err != nil {
		s.err = err
		return false
	}
	if len(rec) != len(s.kinds) {
		s.err = fmt.Errorf("%s line %d: %d fields, want %d", s.path, s.line+1, len(rec), len(s.kinds))
		return false
	}
	row := make([]any, len(rec))
	for i, v := range rec {
		switch s.kinds[i] {
		case text:
			row[i] = v
		case integer:
			if v == "" {
				row[i] = nil
				continue
			}
			n, err := strconv.Atoi(v)
			if err != nil {
				s.err = fmt.Errorf("%s line %d: %w", s.path, s.line+1, err)
				return false
			}
			row[i] = n
		case float:
			if v == "" {
				row[i] = nil
				continue
			}
			x, err := strconv.ParseFloat(v, 64)
			if err != nil {
				s.err = fmt.Errorf("%s line %d: %w", s.path, s.line+1, err)
				return false
			}
			row[i] = x
		}
	}
	s.row = row
	return true
}

func (s *csvSource) Values() ([]any, error) { return s.row, nil }
func (s *csvSource) Err() error             { return s.err }
