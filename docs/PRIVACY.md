# Nearby Live — Privacy Policy (draft)

*Draft for the store listings. Have it reviewed before you publish, and replace the contact
details and anything marked [fill in].*

## What the app does with your location

Nearby Live shows trains, flights, road traffic, weather and events **around you**. That needs
your device's location.

- The app asks for location **only while you use it** ("while in use"). It does not track you in
  the background.
- Your location is used **on your device** to centre the map and to measure distances.
- To fetch nearby data, the app sends your **approximate position** (a point or a box around it)
  to the services listed below. Without the Nearby Live backend, the phone contacts them
  directly. With the backend, the phone contacts only the backend, which contacts them.
- If you turn on **alerts with push notifications**, the backend stores:
  - your device's push token;
  - the location you were last at;
  - your alert settings (distances, watched train numbers, quiet hours).

  This is used only to send those alerts. Turning alerts off, or deleting the app, removes the
  subscription; the backend also drops tokens the push service reports as invalid.
- If you deny location permission, the app runs a built-in demo and sends no location anywhere.

## Services that receive location-based requests

| Service | Why | What is sent |
|---|---|---|
| OpenFreeMap, Esri (map tiles) | Draw the map | Map tile coordinates around the view |
| Open-Meteo | Weather | Approximate coordinates |
| OpenSky Network, adsbdb | Flights | A box around you; flight callsigns |
| Overpass (OpenStreetMap) | Railway and road geometry | A box around you |
| TomTom (if configured) | Road traffic | Sample points around you |
| Ticketmaster (if configured, via backend) | Events | Approximate coordinates and radius |
| Firebase Cloud Messaging (if alerts are on) | Push alerts | Push token and alert text |
| Nearby Live backend (if used) | All of the above, combined | Approximate coordinates, range, alert settings |

Each service has its own privacy policy.

## What we don't do

- No accounts, no advertising, no selling or sharing of data for marketing.
- No location history is kept on the backend: only the latest location of devices that turned
  on push alerts.
- Server logs may contain IP addresses and request paths. They are kept for [fill in] days for
  security and operations.

## Your choices

- Turn location off or deny permission at any time in the system settings.
- Turn alerts off in **Settings → Alerts**.
- Contact [fill in contact email] to ask about or delete your data.

## Children

The app is not directed at children under 13.

## Changes

We will update this page when the app's data use changes. Last updated: [fill in date].
