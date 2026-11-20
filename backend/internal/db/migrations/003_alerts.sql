-- Push alert subscriptions, one per device (FCM registration token).
CREATE TABLE IF NOT EXISTS alert_subscriptions (
    device_token   TEXT PRIMARY KEY,
    platform       TEXT NOT NULL DEFAULT '',          -- android / ios / web
    lat            DOUBLE PRECISION NOT NULL,
    lon            DOUBLE PRECISION NOT NULL,
    train_km       DOUBLE PRECISION NOT NULL DEFAULT 2,   -- 0 = off
    flight_km      DOUBLE PRECISION NOT NULL DEFAULT 0,   -- 0 = off
    late_min       INTEGER NOT NULL DEFAULT 0,            -- 0 = off
    train_numbers  TEXT[] NOT NULL DEFAULT '{}',          -- empty = any train
    quiet_start    INTEGER NOT NULL DEFAULT -1,           -- hour 0-23 local, -1 = none
    quiet_end      INTEGER NOT NULL DEFAULT -1,
    tz_offset_min  INTEGER NOT NULL DEFAULT 330,          -- IST
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
