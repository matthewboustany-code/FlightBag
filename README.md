# FlightBag

An offline-first electronic flight bag (EFB) for iOS/iPadOS, with a
self-hosted data server. Charts, plates, airport data, flight planning,
weather, and live ADS-B In — built around the assumption that cockpit
connectivity is zero.

US/FAA data scope for v1; everything is tagged with a `DataAuthority` so
international providers can plug in later.

## Features

- **Moving map** — MapKit with offline VFR sectional / IFR low / IFR high
  raster charts (local MBTiles), aeronautical overlays (waypoints, airways,
  airspace), TFR/SIGMET/G-AIRMET advisories with altitude filtering, NEXRAD
  radar (internet or FIS-B), a two-finger ruler, and SID/STAR vector overlays
  drawn from CIFP data.
- **Georeferenced plates** — approach plates pinned to the map: FAA IAPs via
  their embedded georef, airport diagrams via runway-shape matching against
  NASR data, and military (DoD) IAPs via RANSAC registration of planview
  RNAV waypoint stars.
- **ADS-B In** — GDL90 over UDP from Stratux/Sentry-class receivers: traffic,
  ownship (preferred over CoreLocation when healthy), and FIS-B uplink
  decoding (METAR/TAF text, NEXRAD mosaic). A hardware-free simulator
  (`gdl90sim`) exercises the whole path.
- **Flight planning & filing** — full ICAO flight plan editor with
  validation (identical rules on client and server), route parsing, navlog
  generation, and assisted filing via a zero-friction handoff to
  1800wxbrief. Direct Leidos LMFS filing is a planned fast-follow behind the
  same `FilingService` protocol.
- **Airports** — FTS5 search, airport detail with raw/decoded METAR & TAF,
  plates viewer.
- **Downloads** — per-region chart/plate/database downloads versioned by
  28-day AIRAC cycle, background `URLSession` with resume, sha256 verify,
  atomic cycle swap, and freshness badges everywhere.

## Repository layout

| Path | What it is |
|---|---|
| `FlightBag/` | iOS/iPadOS app (SwiftUI + MapKit). Features → Services → FlightBagCore; iOS 18+. |
| `Packages/FlightBagCore/` | Shared SPM package, Linux-clean, compiled into both app and server. Targets: `FBModels` (domain types, AIRAC math), `FBFlightPlan` (ICAO plan + validator), `FBProviders` (FAA weather/advisory providers behind injectable `HTTPGetting`), `FBGDL90` (byte-level GDL90 decoding), `FBFISB` (FIS-B uplink decoding). Plus the `gdl90sim` executable. |
| `Server/` | Vapor 4 backend: `/v1/` API (manifest, weather proxy), static artifact hosting, and the per-cycle ingestion pipeline (`ingest-all`). |
| `docs/` | [architecture.md](docs/architecture.md) — locked decisions and the *why*; [code-map.md](docs/code-map.md) — file-by-file guide to the *where*. Read these first. |

## Getting started

### App

Open `FlightBag.xcodeproj` and run the `FlightBag` scheme in the simulator.
No server is required for the core map/planning experience; streamed FAA
charts and live weather need internet.

Useful launch arguments seed deterministic demo state (full table in
[code-map.md](docs/code-map.md)) — e.g. `-adsbDemoSeed YES` for synthetic
traffic, `-flightsDemoSeed YES` for a populated flights tab, and
`-serverBaseURL http://127.0.0.1:8080` to point downloads at a local server.

### ADS-B without hardware

```bash
cd Packages/FlightBagCore && swift run gdl90sim
```

Unicasts a synthetic scene (ownship circuit at KAUS, traffic, FIS-B
METAR/TAF, a drifting NEXRAD cell) to `127.0.0.1:4000`, where the app's
receiver picks it up.

### Server

```bash
cd Server && swift run App serve
```

Serves `/v1/manifest` and `/v1/airports/:id/weather`, plus artifacts under
`Public/artifacts/`. The manifest is empty until an ingest run has produced
artifacts. Ingestion (NASR, d-TPP, CIFP, chart tiles, plate bundles) is
designed to run in Docker — GDAL comes from the image — and is configured
entirely through `FLIGHTBAG_*` env vars; copy `Server/.env.example` to
`Server/.env` and scope it deliberately (everything is ~100+ GB per cycle).

For production bring-up on a NAS, scheduling the daily cycle-aware ingest
cron, and troubleshooting, see [Server/DEPLOY.md](Server/DEPLOY.md).

## Testing

- Package tests: `swift test` in `Packages/FlightBagCore/` (Swift Testing;
  JSON fixtures under `FBProvidersTests/Fixtures/`).
- Server tests: `swift test` in `Server/`.
- App unit tests: the `FlightBagTests` target.
- **Do not run `FlightBagUITests` locally** — they freeze the machine.
  UI verification uses the demo launch arguments above plus
  `xcrun simctl` screenshots instead.

## Data & operational notes

All aviation data artifacts are versioned by 28-day AIRAC cycle
(`DataCycle`). The FAA publishes the next cycle ~20 days early; ingest
HEAD-probes for it daily, builds ahead, and the app downloads ahead and
swaps atomically at the effective instant. IFR enroute editions are 56-day
and publish every other cycle.

Long-lead external dependencies (Leidos LMFS onboarding, FAA NOTAM API key,
Apple multicast entitlement) are tracked in
[architecture.md](docs/architecture.md).

## Disclaimer

FlightBag is a personal project and is **not certified for aviation use**.
It is not a substitute for approved sources of aeronautical information.
Always fly with current, approved data.
