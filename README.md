# Nearby Live

A mobile app that shows live trains, flights, road traffic and weather around you on a futuristic 3D map.
Objects animate in only when they come within the selected range (2 / 5 / 10 / 50 km).

- [PLAN_CHUNKS.md](PLAN_CHUNKS.md) is the build plan, split into chunks.
- [prototype/](prototype/) is the web preview that defines the look and motion:
  - `nearby-live-preview.html` is the neon 3D map version (self-contained).
  - `satellite/index.html` is the satellite imagery version (run `node prototype/serve.js`, then open http://localhost:5173/satellite/).
  - `src/template.html` is the source of both, and `node prototype/src/build.js` rebuilds them.
  - `city-old-delhi.json` holds the OpenStreetMap data (© OpenStreetMap contributors) for the demo area near Red Fort, Old Delhi.
