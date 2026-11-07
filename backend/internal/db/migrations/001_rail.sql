-- Indian Railways reference data (source: datameet/railways, CC0).

CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Every station with its geo location. lat/lon are NULL for the ~300
-- stations the source has no coordinates for.
CREATE TABLE IF NOT EXISTS stations (
    code       TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    state      TEXT NOT NULL DEFAULT '',
    zone       TEXT NOT NULL DEFAULT '',
    address    TEXT NOT NULL DEFAULT '',
    lat        DOUBLE PRECISION CHECK (lat BETWEEN -90 AND 90),
    lon        DOUBLE PRECISION CHECK (lon BETWEEN -180 AND 180),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK ((lat IS NULL) = (lon IS NULL))
);

-- Bounding-box prefilter for nearby queries.
CREATE INDEX IF NOT EXISTS stations_lat_lon_idx ON stations (lat, lon) WHERE lat IS NOT NULL;
-- Fuzzy name search.
CREATE INDEX IF NOT EXISTS stations_name_trgm_idx ON stations USING gin (name gin_trgm_ops);

CREATE TABLE IF NOT EXISTS trains (
    number        TEXT PRIMARY KEY,
    name          TEXT NOT NULL,
    type          TEXT NOT NULL DEFAULT '',
    zone          TEXT NOT NULL DEFAULT '',
    from_code     TEXT NOT NULL DEFAULT '',
    to_code       TEXT NOT NULL DEFAULT '',
    departure     TEXT NOT NULL DEFAULT '',  -- HH:MM IST at origin
    arrival       TEXT NOT NULL DEFAULT '',  -- HH:MM IST at destination
    duration_min  INTEGER,
    distance_km   INTEGER,
    return_train  TEXT NOT NULL DEFAULT ''
);

CREATE INDEX IF NOT EXISTS trains_name_trgm_idx ON trains USING gin (name gin_trgm_ops);

-- Timetable: one row per stop (halts and timing points) in route order.
-- arrival_min / departure_min are minutes from 00:00 IST of the day the
-- train leaves its origin (so day 2 08:30 = 1950).
CREATE TABLE IF NOT EXISTS train_stops (
    train_number  TEXT NOT NULL REFERENCES trains (number) ON DELETE CASCADE,
    seq           INTEGER NOT NULL,
    station_code  TEXT NOT NULL,
    day           INTEGER,
    arrival_min   INTEGER,
    departure_min INTEGER,
    PRIMARY KEY (train_number, seq)
);

CREATE INDEX IF NOT EXISTS train_stops_station_idx ON train_stops (station_code);
