package rail

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// Store reads the rail tables from PostgreSQL.
type Store struct {
	DB *pgxpool.Pool
}

// LoadIndex reads all stations, trains and stops and builds an [Index].
func (s *Store) LoadIndex(ctx context.Context) (*Index, error) {
	stations, err := s.stations(ctx)
	if err != nil {
		return nil, fmt.Errorf("load stations: %w", err)
	}
	trains, err := s.trains(ctx)
	if err != nil {
		return nil, fmt.Errorf("load trains: %w", err)
	}
	stops, err := s.stops(ctx)
	if err != nil {
		return nil, fmt.Errorf("load stops: %w", err)
	}
	return NewIndex(stations, trains, stops), nil
}

func (s *Store) stations(ctx context.Context) ([]Station, error) {
	rows, err := s.DB.Query(ctx, `SELECT code, name, state, zone, address, lat, lon FROM stations`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Station
	for rows.Next() {
		var st Station
		var lat, lon *float64
		if err := rows.Scan(&st.Code, &st.Name, &st.State, &st.Zone, &st.Address, &lat, &lon); err != nil {
			return nil, err
		}
		if lat != nil && lon != nil {
			st.Point = &geo.Point{Lat: *lat, Lon: *lon}
		}
		out = append(out, st)
	}
	return out, rows.Err()
}

func (s *Store) trains(ctx context.Context) ([]Train, error) {
	rows, err := s.DB.Query(ctx, `SELECT number, name, type, zone, from_code, to_code, departure, arrival,
		COALESCE(duration_min, 0), COALESCE(distance_km, 0), return_train FROM trains`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Train
	for rows.Next() {
		var t Train
		if err := rows.Scan(&t.Number, &t.Name, &t.Type, &t.Zone, &t.FromCode, &t.ToCode, &t.Departure, &t.Arrival,
			&t.DurationMin, &t.DistanceKm, &t.ReturnTrain); err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (s *Store) stops(ctx context.Context) (map[string][]Stop, error) {
	rows, err := s.DB.Query(ctx, `SELECT train_number, seq, station_code, COALESCE(day, 0), arrival_min, departure_min
		FROM train_stops ORDER BY train_number, seq`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := map[string][]Stop{}
	for rows.Next() {
		var num string
		var st Stop
		if err := rows.Scan(&num, &st.Seq, &st.StationCode, &st.Day, &st.ArrivalMin, &st.DepartureMin); err != nil {
			return nil, err
		}
		out[num] = append(out[num], st)
	}
	return out, rows.Err()
}

// UpsertStation inserts or updates one station (admin API).
func (s *Store) UpsertStation(ctx context.Context, st Station) error {
	var lat, lon *float64
	if st.Point != nil {
		lat, lon = &st.Point.Lat, &st.Point.Lon
	}
	_, err := s.DB.Exec(ctx, `INSERT INTO stations (code, name, state, zone, address, lat, lon)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		ON CONFLICT (code) DO UPDATE SET name = EXCLUDED.name, state = EXCLUDED.state, zone = EXCLUDED.zone,
			address = EXCLUDED.address, lat = EXCLUDED.lat, lon = EXCLUDED.lon, updated_at = now()`,
		st.Code, st.Name, st.State, st.Zone, st.Address, lat, lon)
	return err
}
