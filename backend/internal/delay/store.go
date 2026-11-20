package delay

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// PgStore persists statuses in train_live_status (one row per journey).
type PgStore struct{ DB *pgxpool.Pool }

// Save upserts a status.
func (s *PgStore) Save(ctx context.Context, st Status) error {
	var lat, lon *float64
	if st.Point != nil {
		lat, lon = &st.Point.Lat, &st.Point.Lon
	}
	_, err := s.DB.Exec(ctx, `INSERT INTO train_live_status
		(train_number, journey_date, delay_min, last_station_code, lat, lon, source, reported_at)
		VALUES ($1, $2::date, $3, $4, $5, $6, $7, $8)
		ON CONFLICT (train_number, journey_date) DO UPDATE SET delay_min = EXCLUDED.delay_min,
			last_station_code = EXCLUDED.last_station_code, lat = EXCLUDED.lat, lon = EXCLUDED.lon,
			source = EXCLUDED.source, reported_at = EXCLUDED.reported_at
		WHERE train_live_status.reported_at <= EXCLUDED.reported_at`,
		st.TrainNumber, st.JourneyDate, st.DelayMin, st.LastStationCode, lat, lon, st.Source, st.ReportedAt)
	return err
}

// LoadSince returns statuses reported after since.
func (s *PgStore) LoadSince(ctx context.Context, since time.Time) ([]Status, error) {
	rows, err := s.DB.Query(ctx, `SELECT train_number, to_char(journey_date, 'YYYY-MM-DD'), delay_min,
		last_station_code, lat, lon, source, reported_at FROM train_live_status WHERE reported_at > $1`, since)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Status
	for rows.Next() {
		var st Status
		var lat, lon *float64
		if err := rows.Scan(&st.TrainNumber, &st.JourneyDate, &st.DelayMin, &st.LastStationCode, &lat, &lon,
			&st.Source, &st.ReportedAt); err != nil {
			return nil, err
		}
		if lat != nil && lon != nil {
			st.Point = &geo.Point{Lat: *lat, Lon: *lon}
		}
		out = append(out, st)
	}
	return out, rows.Err()
}
