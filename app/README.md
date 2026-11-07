# Nearby Live — Flutter app (Android + iOS)

Live nearby **trains, flights, road traffic and weather** on a tilted 3D map with a neon HUD.
Objects animate in only when their real distance (Haversine) is inside the selected range
(2 / 5 / 10 / 50 km) and animate out when they leave.

The look and motion follow the web prototype in [`../prototype/`](../prototype/) and the build plan
in [`../PLAN_CHUNKS.md`](../PLAN_CHUNKS.md) (written for Kotlin; implemented here in Flutter).

## Quick start

```bash
cd app
flutter pub get
flutter run                      # Android device/emulator or iOS simulator
```

Optional live road traffic (TomTom Traffic Flow, free tier):

```bash
flutter run --dart-define=TOMTOM_KEY=your_tomtom_key
```

Use the backend (`../backend`). Trains (timetable plus live delays) and flights then arrive over
one WebSocket (`/v1/live/ws`): a snapshot, then only the changes about every 2 s. The app
re-subscribes when you move or change the range, reconnects with back-off, and falls back to
polling while the connection is down:

```bash
flutter run --dart-define=BACKEND_URL=http://10.0.2.2:8080   # Android emulator → host
```

Build a debug APK:

```bash
flutter build apk --debug
```

Static checks and unit tests:

```bash
flutter analyze
flutter test
```

### Requirements

| | |
|---|---|
| Flutter | 3.27+ (Dart 3.5+); developed against Flutter stable 3.47 |
| Android | minSdk / compileSdk = Flutter defaults; Java 17 |
| iOS | iOS **15.0+** (MapLibre iOS needs 12+); Xcode 15+; CocoaPods or Swift Package Manager |

The iOS project is configured (`ios/Runner/Info.plist` location strings, `ios/Podfile` with
`platform :ios, '15.0'`, deployment target 15.0) but has to be built on a Mac:
`cd ios && pod install` (if you use CocoaPods), then `flutter run` or open `ios/Runner.xcworkspace`.

## Keys and data sources

The app is keyless except for the optional TomTom key.

| Data | Source | Key | Notes |
|---|---|---|---|
| Satellite imagery | Esri World Imagery raster | none | "Imagery © Esri, Maxar, Earthstar Geographics" |
| Vector tiles, 3D buildings | OpenFreeMap (`https://tiles.openfreemap.org/planet`, OpenMapTiles schema) | none | `render_height` drives the extrusions |
| Weather | Open-Meteo `/v1/forecast?current=…` | none | polled every 10 min |
| Flights | OpenSky `/api/states/all` (anonymous), or the backend's `/v1/live?types=flight` with `BACKEND_URL` | none | bbox from range, 20 s polls, dead reckoning, exponential back-off on HTTP 429 |
| Flight route text | adsbdb.com callsign lookup | none | cached per callsign |
| Rail geometry | Overpass API (`railway=rail`) | none | ways stitched into continuous routes, cached per area |
| Trains | `TrainDataSource` → `BackendTrainSource` (with `BACKEND_URL`) or `MockTrainSource` | — | the backend estimates positions from the Indian Railways timetable and station coordinates (8,990 stations); the app snaps them onto the real OSM rail line. Without a backend, the mock runs named trains along real rail lines |
| Road traffic | TomTom Flow Segment Data | `--dart-define=TOMTOM_KEY` | without a key: `MockTrafficSource` puts simulated jams on real major roads from Overpass |
| Events | — | — | Phase 2 (Ticketmaster / PredictHQ); shown in the demo only |

Attribution ("© OpenStreetMap contributors", Esri, OpenFreeMap) is shown on the map above the bottom nav.

## Demo mode

If location permission is denied (or location services are off), the app runs the prototype's
**40-second scripted scenario** in Old Delhi near Red Fort (28.6540, 77.2410): the Rajdhani Express
glides in on the real railway viaduct, AI138 flies over, a jam builds on Ring Road and a music
festival stage rises out of the ground. The demo can also be forced in **Settings → Demo mode**.
The OSM extract it uses is `assets/demo/city-old-delhi.json` (same as `prototype/city-old-delhi.json`).

## How it works

```
lib/
 ├─ main.dart, app.dart          ProviderScope, theme, HomeShell (floating neon bottom nav)
 ├─ core/
 │   ├─ config.dart              keys (--dart-define), poll intervals, Dio provider
 │   ├─ geo/                     GeoPoint, Haversine, bearing, bbox, LocalProjector, Polyline (at / ribbon)
 │   ├─ osm/overpass_api.dart    Overpass client + way stitching
 │   └─ theme/                   palette, card styles, Outfit typography
 └─ features/
     ├─ settings/                range (saved), map style, demo mode, reduce motion (shared_preferences)
     ├─ location/                geolocator permission flow, stream, last known fix
     ├─ weather/                 Open-Meteo API + WMO code → label / overlay variant
     ├─ flights/                 OpenSky API, adsbdb lookup, FlightTrack (dead reckoning + smooth snap), Backoff
     ├─ traffic/                 TomTom source, mock source, congestion model
     ├─ trains/                  TrainDataSource, RailGeometryRepository, BackendTrainSource, MockTrainSource
     ├─ demo/                    DemoCity (asset), DemoScenario (scripted distances), DemoDirector
     ├─ nearby/
     │   ├─ application/         NearbyController: location + range + sources → NearbyState
     │   ├─ domain/presence.dart hidden → entering → present → leaving state machine (+ ScriptedMover)
     │   ├─ scene/               SceneSnapshot, LiveDirector, 3D model builders (train, viaduct, cars, stage)
     │   └─ presentation/        NearbyScreen, MapLibre sync, HUD painters, plane / weather / pins, cards, chrome
     └─ lists/                   Trains / Traffic / Weather / Events list screens
```

* **NearbyController** (Riverpod `Notifier`) asks for location, falls back to demo mode, and polls
  each source on its own interval. Polling pauses while the app is in the background.
* A **SceneDirector** turns state into a `SceneSnapshot` ~15 times per second:
  * `LiveDirector` for real data: a `Presence` state machine per object, trains advanced along their
    rail line, flights dead-reckoned, cars spawned on congested segments.
  * `DemoDirector` for the scripted scenario.
* **MapSceneSync** pushes the snapshot into MapLibre:
  * smoothed camera: pitch 60°, user in the lower-middle, zoom fitted to the range, slow ±7° bearing sway
  * GeoJSON sources for the moving fill-extrusion models (`movers`), viaduct (`rail3d`), traffic flow
    lines with a marching dash, and crowd dots
  * `toScreenLocationBatch` for every overlay anchor
* Flutter overlays are drawn above the map: radar ring + sweep, beams, person marker, motes, contrail,
  the airliner, weather illustration, pins, distance badges and glass cards with a sweeping border.
  They ease between projections, so they move at display rate.
* **Zoom vs range.** The plan's zoom table is used as a cap. The camera zooms out further when
  needed so the range circle fits the screen width. At 10 km and 50 km the 3D models switch to
  pin/icon mode.

## Map styles

* `assets/styles/satellite.json` (default): Esri imagery, faint neon roads, 50 %-opacity 3D buildings coloured by height.
* `assets/styles/neon.json`: navy land, cyan water with glow, green parks, neon roads by class
  (amber motorways, pink primary, violet secondary), buildings blue → cyan → violet → pink → gold by height.

Switch styles in **Settings**.

## Known limits

* Train positions are timetable estimates (backend) or simulated (mock); live delays need a provider (see `../backend/README.md`).
* Anonymous OpenSky access is rate-limited (the app backs off on 429); a free account raises the limits.
* Events are not live yet.
