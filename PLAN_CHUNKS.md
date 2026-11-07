# Nearby Live — Build Plan (Android, Kotlin, Jetpack Compose)

The goal is to rebuild the "Nearby Live" design as a native app on a **real, tilted 3D map** with a
futuristic neon look. The map always shows the real city around the user. Live objects (train, flight,
traffic, weather, and events later) **appear and animate in only when they come within the selected
range** (2 / 5 / 10 / 50 km), at their real positions.

The working web preview is in [prototype/](prototype/). It shows the target look and motion:
[prototype/nearby-live-preview.html](prototype/nearby-live-preview.html). Build the source with
`node prototype/src/build.js`.

---

## 0. Key design decisions (read first)

### 0.1 Real 3D map with MapLibre
- **Map engine:** MapLibre Native for Android (`org.maplibre.gl:android-sdk`). It is open source, needs no
  Google key and supports tilted 3D views with extruded buildings.
- **Compose integration:** wrap `MapView` in `AndroidView` (gives full control over sources and layers).
  The community `maplibre-compose` library is an option later.
- **Tiles (free):**
  - **OpenFreeMap** vector tiles: free, no API key, OpenMapTiles schema with building heights (`render_height`).
  - Fallback: MapTiler free tier (needs a free key).
- **Custom neon style:** our own `style.json` in `assets/`, written for the OpenMapTiles schema. The prototype shows the palette:
  - deep-navy land
  - glowing cyan water
  - vivid green parks
  - neon roads by class (amber motorways, pink primary roads, violet secondary roads)
  - buildings extruded and coloured by height: blue → cyan → violet → pink → gold
- **Camera:** pitch about 60°. A slow bearing sway (±7°) keeps the scene alive. The user sits in the lower-middle of the screen, as in the design.
- **Attribution:** show "© OpenStreetMap contributors" (and the tile provider) on the map. This is required.

### 0.2 Objects sit at their real positions
- The **distance badge** is the real distance: Haversine(user, object).
- **In range** = distance ≤ selected range. Entering range triggers the enter animation and leaving range triggers the exit animation.
- **Range → camera zoom.** The camera zooms so the range circle fits the screen, so anything in range is also on screen:

  | Range | Zoom (approx.) | What the user sees |
  |---|---|---|
  | 2 km | ~14.5 | Close-up 3D city, full models |
  | 5 km | ~13.2 | 3D city, models scaled up |
  | 10 km | ~12.2 | Flatter city, models become glowing icons with trails |
  | 50 km | ~9.9 | Regional view, objects as neon pins and paths, no 3D buildings |

- **Model scale is exaggerated** with zoom, so a train or car stays readable. In the prototype a 150 m train car is used at zoom 14.5.

### 0.3 How each object is drawn

| Object | Technique | Motion |
|---|---|---|
| Train | 3D model built from `FillExtrusionLayer` boxes on a `GeoJsonSource`: body, window band, roof, neon stripe, tapered nose. Elevated track drawn as a viaduct extrusion along the real rail line | Snapped to the real railway geometry. Eases in when arriving and accelerates away when leaving |
| Road traffic | Road lines recoloured by congestion (glow + moving dash). Small 3D car and bus extrusions drive along the jammed segments | Cars move along the road geometry. Density and speed follow congestion |
| Flight | Compose overlay (detailed airliner vector with blinking nav lights) placed with `projection.toScreenLocation()`, plus altitude offset, contrail and ground shadow | Dead reckoning between API polls using speed and heading, so it flies smoothly |
| Weather | Compose overlay (animated sun, cloud and rain) near the user, with a holo beam | Fades and scales in. Always "0 km" |
| Events (later) | 3D stage extrusions + crowd `CircleLayer` + Compose spotlight overlay | Rises out of the ground |
| You | Compose overlay: pulsing range ring with radar sweep, person marker, beams to each object in range | Always on |

Cards, pins and beams are Compose overlays. Their screen positions are recomputed from the map projection
on every camera change and animation frame.

### 0.4 Free / open data sources

| Category | API | Key? | Notes |
|---|---|---|---|
| **Map tiles** | **OpenFreeMap** (OpenMapTiles schema) | **No** | Buildings with heights, roads, rail, water, parks |
| **Flights** | **OpenSky Network** `/api/states/all?lamin&lomin&lamax&lomax` | Optional (a free account gives higher limits) | Live lat/lon, heading, velocity, altitude, callsign. Poll every 15–30 s |
| **Flights (route text, e.g. DEL→BOM)** | adsbdb.com callsign lookup, or OpenSky `/flights/aircraft` | No | Cache the result per callsign |
| **Weather** | **Open-Meteo** `/v1/forecast?current=...` | **No** | Temperature, humidity, wind, rain %, weather code |
| **Road traffic** | **TomTom Traffic Flow API** (free tier ~2,500 req/day) or **HERE Traffic** (free tier) | Free key | `currentSpeed / freeFlowSpeed` gives Light / Moderate / Heavy. TomTom returns segment coordinates to draw |
| **Rail geometry** | **OSM Overpass API** (`railway=rail`) or the vector tiles' `transportation` layer (`class=rail`) | No | Used to snap trains to real tracks |
| **Train – live position (India)** | No official free API. Freemium provider (RapidAPI Indian Railways APIs) behind an interface | Freemium key | If only "last station / next station" is known, interpolate along the rail geometry |
| **Train – other countries** | GTFS-Realtime feeds (Transitland free tier) | Free key | Later / global |
| **Events (later)** | Ticketmaster Discovery API / PredictHQ | Free key | Phase 2 |

> **Flights, weather and map tiles are fully free.** Traffic needs a free key.
> **Indian live train tracking is the weakest link.** It stays behind a `TrainDataSource` interface, with a mock for development.

---

## 1. Architecture

```
app/
 ├─ ui/
 │   ├─ map/            ← NearbyMap (AndroidView + MapView), style loader, camera controller (range → zoom, sway)
 │   ├─ models/         ← 3D model builders: TrainModel, CarModels, StageModel → GeoJSON features (colour, base, height)
 │   ├─ overlays/       ← Compose overlays: RangeRadar, YouMarker, Beams, PlaneOverlay, WeatherOverlay, Pins, Particles
 │   ├─ components/     ← InfoCard, DistanceBadge, LivePill, FeatureRow, BottomNav (neon glass style)
 │   ├─ range/          ← RangeDropdown (2/5/10/50 km)
 │   └─ theme/          ← colours, gradients, typography from the design
 ├─ domain/
 │   ├─ model/          ← NearbyObject (sealed): Train, Flight, Traffic, Weather, Event
 │   └─ usecase/        ← ObserveNearbyUseCase (merges all sources and filters by range)
 ├─ data/
 │   ├─ location/       ← FusedLocationProvider wrapper (Flow<LatLng>)
 │   ├─ flight/         ← OpenSkyApi + FlightRepository (+ dead reckoning)
 │   ├─ weather/        ← OpenMeteoApi + WeatherRepository
 │   ├─ traffic/        ← TomTomApi + TrafficRepository (segments + congestion)
 │   ├─ train/          ← TrainDataSource interface, OverpassRailApi, provider impl, Mock
 │   └─ util/           ← Haversine, bearing, BoundingBox(radius), polyline (arc length, offset, ribbon)
 └─ di/                 ← Hilt modules
```

**Stack:**
- Kotlin, Jetpack Compose (Material 3), MVVM + StateFlow, Hilt
- **MapLibre Native Android**
- Retrofit + OkHttp + kotlinx.serialization, Coroutines/Flow
- Play Services Location, DataStore (saved range)

**Data flow:** `Location Flow` + `Range Flow` → each repository polls on its own interval → `combine` →
filter `distance <= range` → `NearbyUiState`. Then:
- An animation loop (`withFrameNanos`, ~30 fps for map sources) interpolates object positions.
- It pushes model features to the `movers` GeoJsonSource.
- It repositions the Compose overlays.

**Polyline helper** (ported from the prototype): `line(coords)` → points with arc length,
`at(line, s)` → position + heading, `ribbon(line, s0, s1, halfWidth, offset)` → polygon. All 3D models are built from these.

---

## 2. Chunks

Each chunk can be built and run on its own. Finish them in order.

### Chunk 1: Project setup & theme
- Create the Android project: minSdk 26, Compose BOM, Kotlin 2.x, Hilt, Retrofit, serialization, Location, DataStore, **MapLibre**.
- Theme: deep navy, neon blue/cyan accents, card colours (blue = train, purple = flight, red = traffic,
  navy = weather, magenta = events), bold title styles.
- Permissions: `INTERNET`, `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`.
- **Done when:** the app launches with an empty themed screen.

### Chunk 2: 3D map screen & UI shell
- `NearbyMap`: MapView in `AndroidView` with lifecycle handling, loading the OpenFreeMap tiles.
- Neon `style.json` with these layers: land, grid, parks, water + glow, roads + glow by class, 3D buildings (`fill-extrusion`, colour by height, vertical gradient), map light.
- Sky gradient overlay at the top, vignette, scanlines and a soft scan sweep, as in the prototype.
- Chrome on top of the map:
  - header: icon, "Nearby **Live**", subtitle, "Live Updates" pill, settings button
  - **range dropdown**, saved in DataStore
  - feature row
  - bottom nav
- Attribution text.
- **Done when:** the real 3D city around a fixed test location looks like the prototype, with no objects.

### Chunk 3: Camera, range & projection
- `CameraController`:
  - pitch ~60°
  - user placed in the lower-middle of the screen (camera padding)
  - slow bearing sway
  - **zoom-to-range** with a smooth animation when the range changes
- `RangeRadar` overlay around the user's projected position: dashed rotating ring, radar sweep, tick marks, "5 KM" label.
- A `ScreenProjector` that turns LatLng into screen offsets for overlays, refreshed on camera move.
- `YouMarker` overlay: the person and the pin.
- **Done when:** changing the range re-frames the camera, and the ring and marker stay locked to the user.

### Chunk 4: 3D models, overlays & animations (mock data)
- `GeoJsonSource("movers")` + `FillExtrusionLayer` driven by feature properties (colour, base, height).
- `TrainModel`:
  - 6 cars along a rail polyline
  - red-pink end cars, blue middle cars, white roof, window band, neon stripe, tapered nose
  - elevated viaduct and pillars as static extrusions
- `CarModels`: car and bus extrusions on road polylines, lanes by offset, rising out of the ground on enter.
- `StageModel` (for later events): stage, screen, towers, tents, crowd circles.
- Compose overlays:
  - `PlaneOverlay`: vector airliner, blinking lights, contrail, shadow
  - `WeatherOverlay`
  - pins
  - `Beams` from the user to each object
  - floating particles
- `InfoCard` with glass shine, sweeping neon border and coloured glow. `DistanceBadge`, `StatusPill`.
- Enter/exit state machine per object: hidden → entering (ease in) → present (slow crawl) → leaving (accelerate away) → hidden.
- A `MockNearbyRepository` replays the prototype's 40-second scenario.
- **Done when:** the app matches the web prototype with mock data.

### Chunk 5: Location & distance core
- `LocationRepository`: FusedLocation `Flow<LatLng>`, permission flow UI, fallback to the last known location.
- `GeoUtils`: Haversine, bearing, bounding box from a centre and radius, local-metres projection.
- `NearbyViewModel`: combines location + range and exposes `NearbyUiState`. The camera follows the user.
- **Done when:** the map centres on the real location and the range change is reflected in state.

### Chunk 6: Weather (Open-Meteo)
- `OpenMeteoApi` (`current=temperature_2m,relative_humidity_2m,wind_speed_10m,precipitation_probability,weather_code`).
- Map the weather code to a label and to an overlay variant (sun, cloud, rain, storm). Poll every 10 min.
- **Done when:** the weather card and overlay show live values.

### Chunk 7: Flights (OpenSky)
- `OpenSkyApi.states(bbox)` using a bounding box from the range. Parse callsign, lat, lon, heading, velocity, altitude, on_ground.
- Filter by Haversine ≤ range and pick the nearest (others go to the Flights list).
- **Dead reckoning** between polls (position + velocity × time along the heading) for smooth flight.
  Snap gently to each new fix.
- Route text through a callsign lookup, cached. Back off on HTTP 429.
- **Done when:** a real nearby flight flies over the map at its real position with the correct distance.

### Chunk 8: Road traffic (TomTom Flow)
- Sample flow segments around the user inside the range.
- Congestion = `currentSpeed / freeFlowSpeed` → colour of the segment's glow line.
- Spawn car models on congested segments. Density and speed follow congestion.
- Distance = nearest congested segment. Poll every 2–5 min. The key goes in `local.properties` and is read through `BuildConfig`.
- **Done when:** jams appear on the real roads near the user, with moving cars.

### Chunk 9: Trains
- `TrainDataSource` interface with `nearbyTrains(center, radius): List<Train>`.
- `RailGeometryRepository`: rail lines in range from Overpass (cached), stitched into continuous routes.
- `LiveTrainProvider`: freemium provider implementation (name, number, from → to, position or last/next station, status).
- Positioning:
  - with live lat/lon: snap to the nearest rail line
  - with stations only: interpolate along the rail between stations using the schedule
- **Done when:** a real or estimated nearby train runs on the real track with its card ("Moving", "2.3 km").

### Chunk 10: Unified "Nearby" engine & multiple objects
- `ObserveNearbyUseCase` merges all repositories, de-duplicates, and sorts by distance.
- Several objects in one category: draw all models (with a cap). The card shows the nearest one with a "+2 more" chip.
- Bottom-nav tabs (Trains / Traffic / Weather / Events) open a list screen for that category.
- "Live Updates" pill: green when all sources are healthy, amber when some are stale.
- At 10 km and 50 km, switch models to icon and trail mode (see 0.2).
- **Done when:** all categories run live together and changing the range re-frames the map and adds or removes objects with animation.

### Chunk 11: Polish, performance & reliability
- Lifecycle-aware polling and animation (both pause in the background). Use an OkHttp cache and the MapLibre tile cache.
- Frame budget: update the GeoJSON source at ≤30 fps and cap the number of features. Overlays use `graphicsLayer`.
- Error, empty and offline states (show cached tiles and the last known data).
- Alerts & Notifications: notify when a train or flight enters range (WorkManager, optional).
- Settings screen: units, poll intervals, API keys, reduce-motion toggle.
- **Done when:** the app is stable, battery-friendly, and ready to release.

### Chunk 12 (Phase 2): Events & more categories
- Events via Ticketmaster or PredictHQ → stage model + crowd + spotlights at the venue position.
- A pluggable `NearbyCategory` registry, so a new category = data source + model/overlay + card.

---

## 3. What's needed from you
1. **API keys:** TomTom (traffic), an optional OpenSky account, and the chosen train provider.
2. **Optional art:** a nicer airliner and weather illustrations as vector drawables. The prototype's SVGs can be converted to vector drawables and used as they are.
3. A **test location** for development (the prototype uses Old Delhi near Red Fort).

## 4. Open questions
- Which train provider? Is a freemium RapidAPI key OK, or start with mock + rail geometry only?
- Is the app India-only at first? This affects the train provider and traffic sampling.
- OpenFreeMap (no key, community-run) or MapTiler (free tier with key, has an SLA) for tiles in production?
