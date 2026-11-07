# Nearby Live backend

A Go + PostgreSQL API that holds **every Indian Railways station with its geo location**, plus
trains and their full timetables. It uses them to work out where a train is right now: from its
schedule, or from live "last station / next station" data sent by a provider.

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
| `POST /v1/position/estimate` | Position from live stop data (below) |
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

## Limits

* The timetable is a 2016 snapshot without running days. Trains are assumed to run daily and on
  time unless `delay_min` is given. Plug live data in through `POST /v1/position/estimate`.
* Positions follow straight lines between stations; the app snaps them to the real track.
