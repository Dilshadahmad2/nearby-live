#!/usr/bin/env python3
# Usage: python3 scripts/convert_datameet.py <dir with stations.json trains.json schedules.json> data
# Source: https://github.com/datameet/railways (CC0)
"""Convert datameet/railways (CC0) JSON into compact CSVs for the backend seeder."""
import csv, gzip, json, sys, collections
src, out = sys.argv[1], sys.argv[2]

def tmin(s):
    if s in (None, 'None', ''): return None
    h, m, *_ = s.split(':'); return int(h) * 60 + int(m)

st = json.load(open(f'{src}/stations.json'))['features']
codes = set()
with gzip.open(f'{out}/stations.csv.gz', 'wt', newline='') as f:
    w = csv.writer(f); w.writerow(['code', 'name', 'state', 'zone', 'address', 'lat', 'lon'])
    for x in sorted(st, key=lambda x: x['properties']['code']):
        p, g = x['properties'], x['geometry']
        lon, lat = (g['coordinates'] if g else (None, None))
        codes.add(p['code'])
        w.writerow([p['code'], p['name'], p.get('state') or '', p.get('zone') or '', p.get('address') or '',
                    '' if lat is None else round(lat, 6), '' if lon is None else round(lon, 6)])

tr = json.load(open(f'{src}/trains.json'))['features']
numbers = set()
with gzip.open(f'{out}/trains.csv.gz', 'wt', newline='') as f:
    w = csv.writer(f)
    w.writerow(['number', 'name', 'type', 'zone', 'from_code', 'to_code', 'departure', 'arrival', 'duration_min', 'distance_km', 'return_train'])
    for x in sorted(tr, key=lambda x: x['properties']['number']):
        p = x['properties']
        if p['number'] in numbers: continue
        numbers.add(p['number'])
        dur = (p.get('duration_h') or 0) * 60 + (p.get('duration_m') or 0)
        w.writerow([p['number'], p['name'], p.get('type') or '', p.get('zone') or '', p.get('from_station_code') or '',
                    p.get('to_station_code') or '', (p.get('departure') or '')[:5], (p.get('arrival') or '')[:5], dur,
                    p.get('distance') or '', p.get('return_train') or ''])

sch = json.load(open(f'{src}/schedules.json'))
by = collections.defaultdict(list)
for s in sch: by[s['train_number']].append(s)
stats = collections.Counter()
with gzip.open(f'{out}/train_stops.csv.gz', 'wt', newline='') as f:
    w = csv.writer(f)
    w.writerow(['train_number', 'seq', 'station_code', 'day', 'arrival_min', 'departure_min'])
    for num in sorted(by):
        if num not in numbers: stats['stops_unknown_train'] += len(by[num]); continue
        rows = sorted(by[num], key=lambda s: s['id'])  # ids follow route order
        # Absolute minutes from 00:00 of the start day; roll over midnight when
        # 'day' is missing or times go backwards.
        last, day_off = -1, 0
        for seq, s in enumerate(rows, 1):
            a, d = tmin(s['arrival']), tmin(s['departure'])
            if s.get('day'): base = (s['day'] - 1) * 1440
            else: base = day_off
            aa = None if a is None else base + a
            dd = None if d is None else base + d
            if aa is not None and aa < last: aa += 1440; dd = None if dd is None else dd + 1440; base += 1440
            if dd is not None and aa is not None and dd < aa: dd += 1440
            last = max(x for x in (aa, dd, last) if x is not None)
            day_off = (last // 1440) * 1440
            if s['station_code'] not in codes: stats['stop_station_not_in_stations'] += 1
            w.writerow([num, seq, s['station_code'], s.get('day') or '', '' if aa is None else aa, '' if dd is None else dd])
            stats['stops'] += 1
print(dict(stats), 'stations', len(codes), 'trains', len(numbers))
