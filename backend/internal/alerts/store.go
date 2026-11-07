package alerts

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/dilshadahmad2/nearby-live/backend/internal/geo"
)

// PgStore keeps subscriptions in alert_subscriptions.
type PgStore struct{ DB *pgxpool.Pool }

const cols = `device_token, platform, lat, lon, train_km, flight_km, late_min, train_numbers,
	quiet_start, quiet_end, tz_offset_min, updated_at`

func (p *PgStore) Put(ctx context.Context, s Subscription) error {
	if s.TrainNumbers == nil {
		s.TrainNumbers = []string{}
	}
	_, err := p.DB.Exec(ctx, `INSERT INTO alert_subscriptions (`+cols+`)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,now())
		ON CONFLICT (device_token) DO UPDATE SET platform = EXCLUDED.platform, lat = EXCLUDED.lat, lon = EXCLUDED.lon,
			train_km = EXCLUDED.train_km, flight_km = EXCLUDED.flight_km, late_min = EXCLUDED.late_min,
			train_numbers = EXCLUDED.train_numbers, quiet_start = EXCLUDED.quiet_start, quiet_end = EXCLUDED.quiet_end,
			tz_offset_min = EXCLUDED.tz_offset_min, updated_at = now()`,
		s.DeviceToken, s.Platform, s.Location.Lat, s.Location.Lon, s.TrainKm, s.FlightKm, s.LateMin, s.TrainNumbers,
		s.QuietStart, s.QuietEnd, s.TZOffsetMin)
	return err
}

func scan(row pgx.Row) (Subscription, error) {
	var s Subscription
	var lat, lon float64
	var at time.Time
	err := row.Scan(&s.DeviceToken, &s.Platform, &lat, &lon, &s.TrainKm, &s.FlightKm, &s.LateMin, &s.TrainNumbers,
		&s.QuietStart, &s.QuietEnd, &s.TZOffsetMin, &at)
	s.Location = geo.Point{Lat: lat, Lon: lon}
	s.UpdatedAt = at
	return s, err
}

func (p *PgStore) Get(ctx context.Context, token string) (Subscription, bool, error) {
	s, err := scan(p.DB.QueryRow(ctx, `SELECT `+cols+` FROM alert_subscriptions WHERE device_token = $1`, token))
	if errors.Is(err, pgx.ErrNoRows) {
		return Subscription{}, false, nil
	}
	return s, err == nil, err
}

func (p *PgStore) Delete(ctx context.Context, token string) error {
	_, err := p.DB.Exec(ctx, `DELETE FROM alert_subscriptions WHERE device_token = $1`, token)
	return err
}

func (p *PgStore) All(ctx context.Context) ([]Subscription, error) {
	rows, err := p.DB.Query(ctx, `SELECT `+cols+` FROM alert_subscriptions`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Subscription
	for rows.Next() {
		s, err := scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, rows.Err()
}
