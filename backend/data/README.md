# Indian Railways seed data

Converted from [datameet/railways](https://github.com/datameet/railways) (licence: **CC0**).

| File | Rows | Columns |
|---|---|---|
| `stations.csv.gz` | 8,990 (8,697 with coordinates) | code, name, state, zone, address, lat, lon |
| `trains.csv.gz` | 5,208 | number, name, type, zone, from_code, to_code, departure, arrival, duration_min, distance_km, return_train |
| `train_stops.csv.gz` | 417,080 | train_number, seq, station_code, day, arrival_min, departure_min |

`arrival_min` / `departure_min` are minutes from 00:00 IST of the day the train leaves its origin
(day 2, 08:30 = 1950). Stop order follows the source's row ids; midnight roll-overs are fixed when
the source omits the day.

The source is a 2016 snapshot. Timetables change and running days are not included, so positions
are estimates. Missing or wrong station coordinates can be fixed with
`PUT /v1/admin/stations/{code}`. The seeder keeps coordinates added that way when the CSV has none.

Regenerate:

```bash
curl -O https://raw.githubusercontent.com/datameet/railways/master/stations.json
curl -O https://raw.githubusercontent.com/datameet/railways/master/trains.json
curl -O https://raw.githubusercontent.com/datameet/railways/master/schedules.json
python3 scripts/convert_datameet.py . data
```
