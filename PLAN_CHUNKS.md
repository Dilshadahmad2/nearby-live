# Nearby Live — Build Plan in Chunks

**Goal:** a phone app shows a tilted, futuristic 3D map around the user, with live trains, flights,
road traffic, weather and (later) events. Each object animates in when it comes inside the chosen
range (2 / 5 / 10 / 50 km) and animates out when it leaves. A backend holds the live position of
everything and returns what each request asks for: around a point, in a box, or as a live stream.

| | |
|---|---|
| App | Flutter (Android + iOS), Riverpod, MapLibre, `app/` |
| Backend | Go + PostgreSQL, `backend/` |
| Design reference | `prototype/` (web preview, Old Delhi demo) |
| Previous Kotlin plan | git history of this file (commit `66aab02`) |

**Status legend:** ✅ done and verified · 🟡 done, not yet verified on a device or with a real
provider · ⬜ to do

---

## How the parts fit

```
 Phone app (Flutter)                                Backend (Go)
 ┌──────────────────────────┐   WebSocket /v1/live/ws ┌──────────────────────────────────────┐
 │ 3D map + HUD + cards     │◀──────────────────────▶│ Live hub (memory, spatial grid)       │
 │ NearbyController         │   REST /v1/...          │  ├─ trains: timetable + live delays   │
 │  ├─ location, range      │◀──────────────────────▶│  ├─ flights: OpenSky (shared budget)  │
 │  ├─ weather (Open-Meteo) │                         │  └─ next: traffic, events, buses …    │
 │  ├─ traffic (TomTom)     │                         │ Delay service (provider / push)       │
 │  └─ rails (Overpass)     │                         │ PostgreSQL: stations, trains,         │
 └──────────────────────────┘                         │   train_stops, train_live_status      │
                                                       └──────────────────────────────────────┘
```

Without a backend (`BACKEND_URL` unset), the app still works: flights come straight from OpenSky,
trains are simulated on real rail lines, and demo mode replays the prototype.

---

## Phase 1 — App foundation

### Chunk 1: Project setup and theme ✅
- Flutter project for Android and iOS (`com.nearbylive`), Riverpod, dio, geolocator,
  shared_preferences, google_fonts (Outfit), maplibre_gl.
- Neon palette, card styles, typography taken from the prototype.
- Permissions: internet and location (Android manifest, iOS Info.plist). iOS 15 minimum.
- **Done when:** `flutter analyze` is clean. ✅

### Chunk 2: 3D map and screen shell 🟡
- MapLibre map, no Google key. Two styles in `assets/styles/`:
  - Satellite: Esri imagery with see-through 3D buildings from OpenFreeMap.
  - Neon: navy land, cyan water, neon roads, buildings coloured by height.
- Sky gradient, vignette, scanlines and scan sweep.
- Header: icon, "Nearby **Live**", subtitle, Live Updates pill, settings button, range dropdown
  (saved).
- Feature row, five glass cards, bottom nav with a glowing underline, map attribution.
- **Done when:** the screen matches the prototype on a phone. *Layout checked at four phone
  sizes in the layout test (see chunk 17); not yet run on a device.*

### Chunk 3: Camera, range and projection 🟡
- Pitch 60°, user in the lower-middle, zoom fitted to the range, slow ±7° bearing sway.
- Map coordinates turned into screen positions (`toScreenLocationBatch`); overlays ease between
  frames.
- Radar ring with sweep, ticks and "5 KM" label; person marker and "You" label.
- **Done when:** changing the range re-frames the map and the ring stays on the user.
  *Logic tested; not seen on a device.*

### Chunk 4: 3D models, overlays and animations 🟡
- Moving 3D models: train (6 cars on a viaduct), cars and buses, event stage.
- Overlays: airliner with contrail and shadow, weather illustration (by weather code), pins,
  beams, particles, distance badges.
- Enter/exit state machine per object: hidden → entering → present → leaving.
- **Done when:** the app looks and moves like the prototype. *State machine unit-tested; visuals
  not checked on a device.*

### Chunk 5: Location, distance and demo mode ✅
- Location permission flow with a fallback to the last known position.
- Haversine distance, range filtering, bounding boxes, polyline helpers.
- Demo mode (Old Delhi, the prototype's 40-second scenario) when permission is denied, or chosen
  in Settings.
- **Done when:** unit tests for distance, range and the demo script pass. ✅

## Phase 2 — Live data in the app

### Chunk 6: Weather (Open-Meteo) 🟡
- Temperature, humidity, wind, rain chance and weather code, polled every 10 minutes.
- **Done when:** the card shows live values. *Parser tested; not called live.*

### Chunk 7: Flights 🟡
- OpenSky with a box from the range, dead reckoning between polls, smooth correction on each new
  fix, back-off on HTTP 429.
- Route text ("DEL → BOM") from adsbdb.
- When the backend is set, flights come from it instead.
- **Done when:** a real flight moves over the map at the right distance. *Parsing and dead
  reckoning tested.*

### Chunk 8: Road traffic 🟡
- TomTom Flow API with `--dart-define=TOMTOM_KEY`. Without a key, simulated jams run on real
  roads from Overpass.
- Congestion colours, moving cars on jammed roads.
- **Done when:** jams appear on real roads near the user. *Parser tested.*

### Chunk 9: Trains in the app 🟡
- Rail lines from Overpass, joined into continuous routes.
- Trains snapped onto the real track. Sources:
  - backend estimates when `BACKEND_URL` is set;
  - a mock otherwise.
- Cards show the delay ("Moving · 12 min late").
- **Done when:** a train runs on the real track with the right distance and delay. *Snapping and
  parsing tested.*

### Chunk 10: Multiple objects, lists and status ✅
- The nearest object of each kind gets the card; a "+2 more" chip counts the others.
- List screens for Trains, Traffic, Weather and Events.
- Live pill turns amber when a source is stale. Polling pauses in the background.
- **Done when:** `flutter test` passes (53 tests). ✅

## Phase 3 — Backend

### Chunk 11: Station and timetable database ✅
- PostgreSQL tables from datameet/railways (CC0):
  - `stations`: 8,990 stations, 8,697 with locations;
  - `trains`: 5,208 trains;
  - `train_stops`: 417,080 timetable stops.
- Migrations embedded in the server; the seeder can be re-run safely.
- Docker compose with PostgreSQL.
- **Done when:** seeding works on a real PostgreSQL. ✅ (tested on PostgreSQL 16)

### Chunk 12: Station and train API ✅
- Stations: search, nearby, in a map box, by code, and the trains at a station.
- Trains: search, details, route with each stop's location.
- Admin endpoint to add or fix a station's coordinates (needs a token).
- **Done when:** API tests pass. ✅

### Chunk 13: Train position from the timetable ✅
- Works out which run of the train is on the line, including overnight runs.
- Interpolates the position between stops by time, skipping stops without coordinates.
- Statuses: scheduled, running, at station, arrived.
- `POST /v1/position/estimate` for live last/next-station data.
- **Done when:** tests on real data pass (e.g. 12951 Mumbai Rajdhani is between Mumbai and
  Delhi at 23:00). ✅

### Chunk 14: Live train delays 🟡
- Delay service with a configurable provider: URL, headers and JSON field paths are set in the
  environment, so any provider fits.
- Delays are cached, duplicate requests are merged, there is a daily request cap, and they are
  stored in `train_live_status`.
- Push endpoint `PUT /v1/admin/trains/{number}/delay` for any feed.
- Recent provider coordinates replace the timetable estimate.
- **Done when:** tests pass ✅ and a real provider is connected ⬜ (see chunk 18).

### Chunk 15: Live hub 🟡
- In-memory store of everything live, indexed by location.
  - Trains: every running train in India (about 2,170) is recomputed every 30 s.
  - Flights: an OpenSky sweep over India plus refreshes around requests, sharing one credit
    budget.
- `/v1/live`, `/v1/live/bbox`, `/v1/live/{kind}/{id}`, `/v1/live/status`.
- **Done when:** tests pass ✅ and a real OpenSky response is seen ⬜ (OpenSky is blocked in the
  build sandbox).

### Chunk 16: WebSocket live stream ✅
- `/v1/live/ws`: subscribe to an area, get everything there first, then only the changes
  (moved, changed, entered, left).
- Numbered messages so a missed one is detected; ping; connection cap.
- The app's stream client reconnects, re-subscribes on move or range change, and falls back to
  polling.
- **Done when:** a real WebSocket round trip and the app tests pass. ✅

---

## Phase 4 — Make it real

### Chunk 17: Run on real devices 🟡
- ✅ Android SDK installed; `flutter build apk --debug` succeeds (CI builds it on every PR too).
- ✅ A layout test renders the real Nearby screen (demo scenario, all five cards) at 360×780,
  390×844, 412×915 and 430×932, plus Hindi at 360×780. It fails on any overflow; screenshots are
  in `docs/screenshots`. It found and fixed three layout bugs:
  - the weather card overflowed;
  - the feature-row labels wrapped badly;
  - the cards overlapped the feature row.
- ⬜ **Needs you:** run on a real phone. The native map, the screen projection (Android
  physical pixels vs iOS points), frame rate and battery cannot be checked without one; this
  machine has no emulator acceleration.
- ⬜ **Needs a Mac:** iOS build (`pod install`, Xcode signing).
- **Done when:** the app runs smoothly on one Android and one iOS device.

### Chunk 18: Real live train source ⬜ (needs your decision and key)
- The code is ready: a configurable delay provider (URL, headers, JSON paths), a push endpoint,
  caching, a request budget, persistence and the WebSocket stream.
- ⬜ Choose a provider whose terms allow your use (for example RapidAPI IRCTC APIs or
  RailRadar), set `DELAY_PROVIDER_URL` and the paths, and check them against real responses.
- ⬜ Optional: running days, so trains that don't run today are hidden.
- **Done when:** a real delayed train is shown at the right place with the right delay.

### Chunk 19: Flight feed in production ⬜ (needs an account)
- The code is ready: OAuth2 client credentials, credit budget, 429 back-off, an India-wide
  sweep plus on-demand regions.
- ⬜ Create an OpenSky account and set `OPENSKY_CLIENT_ID` / `OPENSKY_CLIENT_SECRET`. Check
  OpenSky's terms; commercial use needs their permission.
- **Done when:** flights over a city stay fresh (under 30 s) all day within budget.

### Chunk 20: Traffic and weather in the backend ✅ (real upstreams not reachable from the build machine)
- Weather from Open-Meteo per ~11 km cell; traffic from TomTom with the key on the server; both
  are on-demand area sources in the hub.
- The app gets trains, flights, weather, traffic, events and buses/metro over one WebSocket and
  needs no API keys. Local polling only runs as a fallback.

### Chunk 21: Deploy and operate 🟡
- ✅ CI (GitHub Actions):
  - backend: gofmt, vet, race tests, seeding a real PostgreSQL, Redis integration test, Docker
    build;
  - app: analyze, tests, debug APK artifact.
- ✅ `/metrics` (Prometheus): requests, latency, live objects, feed age and errors, streams,
  provider budgets.
- ✅ `deploy/docker-compose.prod.yml`: PostgreSQL + API + Caddy (automatic HTTPS for `wss://`)
  + nightly backups.
- ⬜ **Needs you:** a server and a domain; then point the app's `BACKEND_URL` at it.
- **Done when:** a release build talks to the hosted backend.

### Chunk 22: Alerts and notifications 🟡
- ✅ Backend:
  - subscriptions (`/v1/alerts/subscriptions/{token}`);
  - rules: train near, watched train late, flight overhead; quiet hours; cooldown;
  - delivery through FCM HTTP v1 or a webhook. Tested on real data.
- ✅ App: local notifications with the same rules; **Settings → Alerts**.
- ⬜ **Needs a Firebase project:** add `firebase_messaging` and the config files, then register
  the FCM token, so alerts also arrive while the app is closed.

### Chunk 23: Scale out ✅
- `ROLE=worker` (all feeds, alerts and upstream budgets) plus any number of `ROLE=api` instances,
  sharing the hub through Redis pub/sub and snapshots. Delay pushes reach every instance.
- Tested end to end on real PostgreSQL + Redis. `deploy/docker-compose.cluster.yml` runs two
  API instances behind Caddy.

### Chunk 24: Events and public transport 🟡 (needs keys / feed URLs)
- ✅ Events from Ticketmaster (`TICKETMASTER_KEY`): nearest event in range gets the card, pin,
  rising stage, crowd and spotlights.
- ✅ Buses and metro from any GTFS-Realtime feed (`GTFS_RT_FEEDS`, e.g. Delhi's Open Transit
  Data portal): small pins and a list.
- ⬜ Real responses not yet seen (no keys here). Ships (AIS) not started.

### Chunk 25: Polish and store release 🟡
- ✅ App icon (`tool/make_icons.py`) and navy splash on Android and iOS.
- ✅ Release signing via `android/key.properties`.
- ✅ English and हिन्दी (system or chosen language); screen-reader labels on cards; offline
  banner; bundled fonts; reduce motion.
- ✅ Privacy policy draft (`docs/PRIVACY.md`).
- ⬜ **Needs you:** store listings, screenshots from a real device, a reviewed privacy policy,
  developer accounts, then the Play / App Store test tracks.
- **Done when:** the app is published to Play Store and App Store test tracks.

---

## What only you can do next
1. Run the debug APK on a phone (download it from the CI artifact or build it locally) and send
   back anything that looks off. The native map is the one part never seen.
2. Pick and pay for a live-train provider, and give the backend its key and field paths
   (chunk 18).
3. Create an OpenSky account (chunk 19); optionally TomTom, Ticketmaster and GTFS-RT keys.
4. Rent a server and a domain, then deploy with `deploy/docker-compose.prod.yml` (chunk 21).
5. Create a Firebase project for push alerts (chunk 22).
6. Developer accounts and store listings (chunk 25).

## Open decisions
1. **Train provider:** which paid live-train API, and its budget.
2. **OpenSky:** account only, or a paid flight feed as well?
3. **Hosting:** where the backend runs, and the domain for `wss://`.
4. **Coverage:** India only at first, or global (affects the train source and the flight box)?
5. **Tiles:** OpenFreeMap (no key, community-run) or MapTiler (free tier with a key and an SLA)
   for production?
