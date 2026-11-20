-- Live running status per journey (delay, last station, optional live
-- coordinates), from a provider or pushed by a feed.
CREATE TABLE IF NOT EXISTS train_live_status (
    train_number      TEXT NOT NULL,
    journey_date      DATE NOT NULL,
    delay_min         INTEGER NOT NULL,
    last_station_code TEXT NOT NULL DEFAULT '',
    lat               DOUBLE PRECISION,
    lon               DOUBLE PRECISION,
    source            TEXT NOT NULL DEFAULT '',
    reported_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (train_number, journey_date)
);

CREATE INDEX IF NOT EXISTS train_live_status_reported_idx ON train_live_status (reported_at);
