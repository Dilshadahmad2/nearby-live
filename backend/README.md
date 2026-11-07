# Nearby Live backend

A Go + PostgreSQL service that holds **every Indian Railways station with its geo location**, plus
trains and their full timetables. On top of that it runs a **live hub**: the current position of
every train in India and every aircraft over India, kept in memory and answered by area:

* `/v1/live?lat&lon&radius_km&types=train,flight`
* `/v1/live/bbox`

Train positions come from the timetable, shifted by **live delays** from a configurable delay
API or from any feed that pushes them. Flights come from OpenSky, with one shared credit budget
for all users.

The Flutter app (`../app`) uses it for the Trains layer when built with
`--dart-define=BACKEND_URL=…`.

## Run

With Docker (PostgreSQL + API; the database seeds itself on first start):

```bash
cd backend
docker compose up --build
curl localhost:8080/healthz
```

Without Docker, against your own PostgreSQL 13+ (`pg_trgm` extension available):

```bash
cd backend
export DATABASE_URL='postgres://user:pass@localhost:5432/nearby?sslmode=disable'
go run ./cmd/seed -data ./data      # create tables + load 8,990 stations, 5,208 trains, 417k stops
go run ./cmd/server                 # http://localhost:8080
```

Quick look without any database (read-only, straight from the CSVs):

```bash
go run ./cmd/server                 # DATABASE_URL unset → serves data/*.csv.gz
```

Tests (no database needed; they include checks against the real data):

```bash
go test ./...
```

Point the app at it (Android emulator → host machine is `10.0.2.2`):

```bash
cd ../app && flutter run --dart-define=BACKEND_URL=http://10.0.2.2:8080
```

## Database

Migrations are embedded (`internal/db/migrations`) and run automatically by both commands.

```sql
stations    (code PK, name, state, zone, address, lat, lon, updated_at)
            -- index on (lat, lon); trigram index on name
trains      (number PK, name, type, zone, from_code, to_code, departure, arrival,
             duration_min, distance_km, return_train)
train_stops (train_number FK, seq, station_code, day, arrival_min, departure_min)
            -- PK (train_number, seq); index on station_code
train_live_status (train_number, journey_date, delay_min, last_station_code, lat, lon,
                   source, reported_at)   -- latest live status per journey
alert_subscriptions (device_token PK, platform, lat, lon, train_km, flight_km, late_min,
                     train_numbers[], quiet_start, quiet_end, tz_offset_min, updated_at)
```

`arrival_min` / `departure_min` count minutes from 00:00 IST of the day the train leaves its
origin, so overnight trains need no date logic. About 300 stations have no coordinates in the
source. Positions are bridged across them, and you can add coordinates with the admin API.

Data: [datameet/railways](https://github.com/datameet/railways), **CC0**. See `data/README.md`
for the format and how to regenerate it.

The server loads all tables into memory at start-up (about 20 MB), so queries do not hit the
database. `POST /v1/admin/reload` refreshes that copy after edits.

## API

All responses are JSON. Lists look like `{"count": n, "items": [...]}`.

| Method & path | What it does |
|---|---|
| `GET /healthz` | Status and row counts |
| `GET /v1/stations?q=delhi&limit=20` | Search by code (exact) or name |
| `GET /v1/stations/{code}` | One station, e.g. `/v1/stations/NDLS` |
| `GET /v1/stations/nearby?lat=&lon=&radius_km=5&limit=50` | Stations near a point, nearest first, with `distance_km` |
| `GET /v1/stations/bbox?south=&west=&north=&east=` | Stations in a map viewport |
| `GET /v1/stations/{code}/trains` | Trains that stop at or pass the station, with times |
| `GET /v1/trains?q=rajdhani` | Search trains by number or name |
| `GET /v1/trains/{number}` | Train details |
| `GET /v1/trains/{number}/route` | Timetable with each stop's location |
| `GET /v1/trains/{number}/position?at=RFC3339&delay_min=0` | Estimated position from the timetable |
| `GET /v1/trains/nearby?lat=&lon=&radius_km=5&at=` | Trains estimated to be within the radius now (used by the app) |
| `GET /v1/trains/{number}/live` | Same, after fetching a fresh live delay from the provider |
| `POST /v1/position/estimate` | Position from live stop data (below) |
| `GET /v1/live?lat=&lon=&radius_km=10&types=train,flight&limit=100` | **Everything live near a point**, nearest first |
| `GET /v1/live/bbox?south=&west=&north=&east=&types=` | Everything live in a map viewport |
| `GET /v1/live/{kind}/{id}` | One object, e.g. `/v1/live/train/12951`, `/v1/live/flight/800c1b` |
| `GET /v1/live/status` | Feed health: counts, last update, last error, delay budget, OpenSky credits, open streams |
| `GET /v1/live/ws` (WebSocket) | **Live stream** of everything near a point: a snapshot, then only changes |
| `PUT /v1/admin/trains/{number}/delay` | Push a live delay / position for a train (admin) |
| `PUT /v1/alerts/subscriptions/{device_token}` | Register or update a device's push alert settings |
| `GET` / `DELETE /v1/alerts/subscriptions/{device_token}` | Read or remove them |
| `GET /metrics` | Prometheus metrics |
| `PUT /v1/admin/stations/{code}` | Add or fix a station (`Authorization: Bearer $ADMIN_TOKEN`) |
| `POST /v1/admin/reload` | Reload the in-memory copy from the DB (admin) |

### Position estimates

```bash
curl 'localhost:8080/v1/trains/12951/position?at=2026-11-07T23:00:00%2B05:30'
```

```json
{
  "train": {"number": "12951", "name": "Mumbai Central-New Delhi Rajdhani Express", "from_code": "BCT", "to_code": "NDLS", "...": "..."},
  "position": {
    "status": "running",
    "location": {"lat": 22.8408, "lon": 74.0941},
    "bearing_deg": 81.3,
    "speed_kmh": 55.3,
    "segment_progress": 0.8,
    "prev_stop": {"seq": 96, "code": "MAM", "name": "MANGAL MAHUDI", "location": {"lat": 22.83578, "lon": 74.058492}, "departure": "2026-11-07T22:56:00+05:30"},
    "next_stop": {"seq": 97, "code": "USRA", "name": "USRA", "location": {"lat": 22.842055, "lon": 74.102942}, "arrival": "2026-11-07T23:01:00+05:30"},
    "journey_start_date": "2026-11-07T00:00:00+05:30",
    "delay_min": 0,
    "estimated": true
  }
}
```

How the estimate is calculated:

1. Find which journey is on the line: the train may have left today or a few days ago.
2. Find the stop it is dwelling at, or the two stops it is between.
3. Interpolate along the great circle between the nearest stops that have coordinates, by time.

The status is one of `scheduled`, `running`, `at_station`, `arrived` or `unknown`. The app then
snaps the point onto the real OSM rail line.

If a live provider reports where the train last was and where it goes next, post those stops.
The station table supplies the coordinates:

```bash
curl -X POST localhost:8080/v1/position/estimate -H 'Content-Type: application/json' -d '{
  "stops": [
    {"code": "NDLS", "departure": "2026-11-07T16:55:00+05:30"},
    {"code": "MTJ",  "arrival":   "2026-11-07T18:40:00+05:30"}
  ],
  "delay_min": 12
}'
```

## Live data

### The live hub

```
                     ┌─────────────── live hub (memory, 0.5° grid) ───────────────┐
 timetable + delays ─▶ trains   (every train in India, recomputed every 30 s)       │──▶ /v1/live, /v1/live/ws
 OpenSky             ─▶ flights  (India sweep + on-demand refresh around requests)  │──▶ /v1/live/bbox
 Open-Meteo          ─▶ weather  (one object per ~11 km cell, cached 10 min)       │──▶ /v1/live/{kind}/{id}
 TomTom (server key) ─▶ traffic  (road segments per ~5 km area, cached 3 min)      │
 (next: events, buses, ships …)                                                     │
                     └────────────────────────────────────────────────────────────┘
```

Each object has `id`, `kind`, `location`, `heading_deg`, `speed_kmh`, `label`, `name`,
`status` and `source`. Depending on the kind it also has `altitude_m`, `delay_min` and
`prev_stop`/`next_stop`.

Flights are dead-reckoned to the request time (capped at 3 minutes) and dropped after 5 minutes
without a fix. A new kind only needs a source that calls `hub.Replace` (full snapshot) or
`hub.Upsert` (regional updates).

```bash
curl 'localhost:8080/v1/live?lat=28.654&lon=77.241&radius_km=5&types=train,flight'
```

### Weather and traffic

These two are fetched **on demand** for the area of each request or stream subscription. Every
user in the same area shares one upstream request, so the TomTom key never leaves the server.

| Kind | Object | Notes |
|---|---|---|
| `weather` | `status` / `label` (e.g. "Partly Cloudy"); `extra.temperature_c`, `humidity_pct`, `wind_kmh`, `rain_pct`, `code` | Always on (Open-Meteo, no key). The nearest cell is included even when its centre is outside a small radius. |
| `traffic` | `status` = free / light / moderate / heavy / closed; `label` = road class; `speed_kmh`; `extra.free_flow_kmh`, `current_kmh`, `closed`, `coordinates` ([lon, lat] line) | Only with `TOMTOM_KEY`. Each refresh is 7 samples, capped by `TOMTOM_DAILY_REQUESTS` (default 2000). |

### WebSocket stream (`/v1/live/ws`)

Connect, subscribe to an area, get a snapshot, then a `diff` every interval. A diff holds only
objects that moved (by more than about 1 m), changed (delay, status, …), entered or left.
Sending `subscribe` again, for example after the user moves or changes range, gives a fresh
snapshot.

```jsonc
// client → server
{"type": "subscribe", "lat": 28.654, "lon": 77.241, "radius_km": 10,
 "types": ["train", "flight"], "limit": 200, "interval_ms": 2000}
{"type": "ping"}

// server → client
{"type": "hello", "protocol": 1, "min_interval_ms": 1000}
{"type": "snapshot", "seq": 1, "at": "…", "items": [ {…object, "distance_km": 1.1}, … ]}
{"type": "diff", "seq": 2, "at": "…", "upsert": [ … ], "remove": [{"kind": "flight", "id": "800c1b"}]}
{"type": "status", "layers": [ … ]}          // every 30 s
{"type": "pong"} / {"type": "error", "message": "…"}
```

* Objects have the same shape as in `/v1/live`. `seq` goes up by one per snapshot or diff; if
  you see a gap, re-subscribe.
* The fastest interval is `WS_MIN_INTERVAL` (default 1 s). The radius is capped at 200 km and
  the limit at 500.
* Subscribing to flights also triggers the on-demand OpenSky refresh for that area.
* The server pings every 25 s and closes dead connections. Connections are capped by
  `WS_MAX_CONNS` (HTTP 503 above it).
* Browser clients are limited by `WS_ORIGINS` when it is set. Native apps send no `Origin`
  header.

Try it:

```bash
npx wscat -c ws://localhost:8080/v1/live/ws
> {"type":"subscribe","lat":28.654,"lon":77.241,"radius_km":5,"types":["train"]}
```

### Live train delays

There is no free official Indian live-train API. The backend accepts live status two ways.
Positions use the most recent status less than 6 hours old. If the status includes coordinates
less than 10 minutes old, those replace the timetable estimate.

**1. A delay API you subscribe to.** Delays are fetched on demand: by
`/v1/trains/{n}/live`, `/v1/trains/{n}/position?live=1` and `/v1/trains/nearby?live=1` (nearest 5
trains). They are cached for `DELAY_TTL`, duplicate requests are merged, and calls are capped by
`DELAY_DAILY_LIMIT`. Results are stored in `train_live_status`.

Providers change their response formats, so nothing is hard-coded. You set the URL, the headers
and the JSON paths:

| Variable | Example |
|---|---|
| `DELAY_PROVIDER_URL` | `https://example-provider/api/live?trainNo={number}&startDay={start_day}` |
| `DELAY_PROVIDER_HEADERS` | `X-RapidAPI-Key: <key>; X-RapidAPI-Host: <host>` |
| `DELAY_PATH` | `data.delay` (minutes; also accepts `"15 min"`, `"1h 5m"`, `"01:05"`, `"On Time"`) |
| `DELAY_STATION_PATH` | `data.current_station_code` (optional) |
| `DELAY_LAT_PATH` / `DELAY_LON_PATH` | live coordinates, if the provider has them (optional) |
| `DELAY_OK_PATH` / `DELAY_MESSAGE_PATH` | e.g. `status` / `message` (optional) |

URL placeholders: `{number}`, `{date}` (YYYY-MM-DD), `{date_compact}`, `{date_dmy}`, and
`{start_day}` (0 = left origin today IST, 1 = yesterday, …).

> Check the field paths against a real response from your plan before going live. RapidAPI's
> IRCTC APIs and RailRadar both return delay and current-station fields, but their names were
> not verified for this code. The provider adapter is `internal/delay/http_provider.go`.

Respect each provider's terms. Do not scrape sites whose terms forbid it.

**2. Push from any feed** (your own job, a partner feed, GPS on the train):

```bash
curl -X PUT localhost:8080/v1/admin/trains/12951/delay -H "Authorization: Bearer $ADMIN_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"delay_min": 25, "last_station_code": "KOTA", "location": {"lat": 25.18, "lon": 75.83}, "source": "partner"}'
```

`journey_date` (YYYY-MM-DD) is optional. Without it, the report applies to the journey currently
on the line.

### Flights (OpenSky)

* **Sweep:** a background sweep of `OPENSKY_BBOX` (India by default) runs about every
  `OPENSKY_SWEEP_INTERVAL`. By default that interval is set so the sweeps use half the daily
  credits.
* **On demand:** each `/v1/live` request that includes flights refreshes the area around the
  request when it is older than 30 s. A small box costs 1 credit.
* **Budget:** credits are counted per UTC day. Requests stop at the budget and back off on HTTP
  429 (`X-Rate-Limit-Retry-After-Seconds`).
* **Credentials:** set `OPENSKY_CLIENT_ID` / `OPENSKY_CLIENT_SECRET` (OAuth2 client credentials
  from an OpenSky account) for a much larger budget than anonymous access.
  `OPENSKY_DAILY_CREDITS` defaults to 4000 with credentials and 400 without.

Check OpenSky's current terms and limits; commercial use needs their permission.

### Push alerts

Devices register what they want to hear about. A worker checks the hub every `ALERT_INTERVAL`
(30 s) and sends:
- **Train nearby:** any train within `train_km`, or only the listed `train_numbers`.
- **Train running late:** a watched train at least `late_min` late. It is re-sent for every
  further 15 minutes of delay.
- **Flight overhead:** a flight within `flight_km`.

Each alert is sent at most once per `ALERT_COOLDOWN` (1 h). Quiet hours are respected, and
device tokens that FCM rejects are removed.

```bash
curl -X PUT localhost:8080/v1/alerts/subscriptions/$FCM_TOKEN -d '{
  "platform": "android", "location": {"lat": 28.654, "lon": 77.241},
  "train_km": 2, "flight_km": 3, "late_min": 30, "train_numbers": ["12951"],
  "quiet_start": 22, "quiet_end": 7, "tz_offset_min": 330}'
```

Delivery channels:
- **FCM:** set `FCM_SERVICE_ACCOUNT_FILE` (a Firebase service-account JSON key). FCM covers
  Android and iOS; upload your APNs key in the Firebase console.
- **Webhook:** set `ALERT_WEBHOOK_URL` and every alert is also POSTed there as JSON.
- **Neither set:** alerts are only logged.

The app sends PUT again when the user moves. Its local notifications use the same rules (see
`app/README.md`).

### Fixing station data

```bash
curl -X PUT localhost:8080/v1/admin/stations/XYZ \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"name": "Example Halt", "state": "Delhi NCT", "zone": "NR", "location": {"lat": 28.61, "lon": 77.20}}'
```

Re-seeding keeps coordinates added this way when the source has none.

## Configuration

| Variable | Default | |
|---|---|---|
| `DATABASE_URL` | — | PostgreSQL URL; unset = read-only CSV mode |
| `PORT` | `8080` | |
| `DATA_DIR` | `data` | Seed CSVs |
| `SEED_IF_EMPTY` | `true` | Seed on start when `stations` is empty |
| `ADMIN_TOKEN` | — | Enables the admin endpoints |
| `LOG_LEVEL` | `info` | `debug` logs every request |
| `LIVE_TRAINS_INTERVAL` | `30s` | How often all train positions are recomputed |
| `DELAY_PROVIDER_URL`, `DELAY_PROVIDER_HEADERS`, `DELAY_PATH`, … | — | Live delay API (see above) |
| `DELAY_TTL` / `DELAY_DAILY_LIMIT` | `3m` / `500` | Cache time and daily request cap for the delay API |
| `LIVE_FLIGHTS` | `true` | OpenSky feed on or off |
| `OPENSKY_CLIENT_ID` / `OPENSKY_CLIENT_SECRET` | — | OAuth2 client credentials |
| `OPENSKY_DAILY_CREDITS` / `OPENSKY_SWEEP_INTERVAL` / `OPENSKY_BBOX` | auto / auto / India | |
| `WS_MAX_CONNS` / `WS_MIN_INTERVAL` / `WS_ORIGINS` | `1000` / `1s` / any | WebSocket stream limits |
| `WEATHER_MAX_AGE` | `10m` | Weather cache per cell |
| `TOMTOM_KEY` / `TOMTOM_DAILY_REQUESTS` / `TRAFFIC_MAX_AGE` | — / `2000` / `3m` | Traffic layer (off without a key) |
| `FCM_SERVICE_ACCOUNT_FILE` / `ALERT_WEBHOOK_URL` | — | Push alert delivery |
| `ALERT_INTERVAL` / `ALERT_COOLDOWN` | `30s` / `1h` | Alert evaluation |

## Deploy

`deploy/docker-compose.prod.yml` runs four services on any Linux VM:
- PostgreSQL;
- the API;
- **Caddy**, which gets HTTPS certificates automatically, so the app uses `https://` and `wss://`;
- a nightly `pg_dump` backup that keeps the last 14 dumps.

Point a DNS name at the VM, then:

```bash
cd backend/deploy
cp ../.env.example .env        # ADMIN_TOKEN, delay provider, OpenSky credentials …
POSTGRES_PASSWORD=change-me DOMAIN=api.example.com docker compose -f docker-compose.prod.yml up -d --build
```

Build the app against it:

```bash
flutter build apk --dart-define=BACKEND_URL=https://api.example.com
```

### Monitoring

`GET /metrics` serves Prometheus text format. Caddy hides it from the public; scrape
`api:8080/metrics` inside the network.

| Metric | Meaning |
|---|---|
| `nearby_http_requests_total{method,route,status}` | Request count |
| `nearby_http_request_duration_seconds` | Latency histogram per route |
| `nearby_live_objects{kind}` | Objects held per kind |
| `nearby_live_age_seconds{kind}` | Time since that kind's last refresh |
| `nearby_live_feed_error{kind}` | 1 when the last refresh failed |
| `nearby_stream_connections` | Open WebSocket streams |
| `nearby_delay_provider_requests_today`, `nearby_opensky_credits_used_today`, `nearby_opensky_daily_credits`, `nearby_tomtom_requests_today` | Budgets |

Suggested alerts:
- `nearby_live_age_seconds{kind="train"} > 120`
- `nearby_live_feed_error == 1` for 15 minutes
- OpenSky credits above 90 % of the daily budget

CI (`.github/workflows/ci.yml`) runs on every pull request:
- backend: gofmt, vet, race tests, seeding a real PostgreSQL, Docker build;
- app: analyze, tests, debug APK uploaded as an artifact.

## Limits

* The timetable is a 2016 snapshot without running days. Trains are assumed to run daily and on
  time unless a live delay is known.
* State is held in one process. To run several instances, put the hub behind Redis (GEO commands)
  or PostGIS, and run the feeds as one worker.
* Positions follow straight lines between stations; the app snaps them to the real track.
