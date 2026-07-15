# FlightBag Code Map

File-level guide for navigating the codebase without reading everything.
Companion to [architecture.md](architecture.md), which records the *why*;
this records the *where*. Regenerate when the layout shifts (line counts
are approximate as of 2026-07-15; ~9,700 lines of Swift total).

## Top level

| Path | What it is |
|---|---|
| `FlightBag/` | iOS/iPadOS app target (SwiftUI + some UIKit/MapKit) |
| `Packages/FlightBagCore/` | Shared SPM package, Linux-compatible, used by app and server |
| `Server/` | Vapor 4 backend: `/v1/` API + AIRAC-cycle ingestion commands |
| `FlightBagTests/`, `FlightBagUITests/` | App-target tests. **Never run XCUITests locally** — they freeze this Mac; verify via launch-arg hooks + `simctl` screenshots |

## App target (`FlightBag/`)

Dependency direction: **Features → Services → FlightBagCore**. Features never
touch GRDB or providers directly.

### App shell (`App/`)
- `FlightBagApp.swift` — entry point, SwiftData container setup
- `App/RootTabView.swift` — `AppTab` enum + tab bar (Map, Flights, Airports, Downloads, Settings)
- `App/AppEnvironment.swift` — `AppEnvironment` observable: shared app state, `ActiveMapRoute` (flight → map handoff)
- `App/UserModels.swift` — SwiftData models: `Flight`, `ClearanceRecord`, `FlightDocument`, `AircraftProfile` (CloudKit-safe schema)
- `App/DisclaimerView.swift` — first-run legal gate

### Services (`Services/`) — the app's data layer
- `AeroDatabase.swift` (~450 ln, largest service) — GRDB read-only wrapper over per-cycle `aero.sqlite`. FTS5 search (`SearchResult`), `AirportDetail`, map queries (`MapWaypoint`, `AirwayLine`), airspace R*Tree lookups. Conforms to `WaypointResolving` for the route parser.
- `ChartStore.swift` — discovers downloaded MBTiles chart sets (`ChartSet`)
- `PlateStore.swift` — actor; downloads/caches terminal procedure PDFs
- `WeatherStore.swift` — actor; METAR/TAF fetch + cache (`StationWeather`)
- `AdvisoryStore.swift` — fetches TFR/SIGMET/G-AIRMET via FBProviders
- `AirspaceStore.swift` — loads airspace polygons for map viewport
- `PositionSource.swift` — `PositionSource` protocol + `CoreLocationPositionSource`; `OwnshipPosition`. (GDL90/ADS-B source plugs in here later.)

### Features (`Features/`)
**Map** — the most complex feature; MapKit, not SwiftUI Map:
- `MapHomeView.swift` (~365 ln) — SwiftUI host: layer pickers, advisory inspection sheets, search
- `EFBMapView.swift` (~510 ln) — `UIViewRepresentable` wrapping `MKMapView`; `Coordinator` owns all delegate logic, annotations (airport/waypoint/ownship), overlay z-ordering, tap handling
- `MapLayersState.swift` — `ChartKind` (VFR/IFR-low/IFR-high) + observable toggle state for all layers
- `MBTilesOverlay.swift` — `MKTileOverlay` reading local MBTiles via GRDB
- `StreamingChartOverlay.swift` — FAA tile streaming with over-zoom (uses `TileResampler.swift`)
- `MapAdvisories.swift` — `AdvisoryCategory`, `AdvisoryPolygon`, `AdvisoryOverlayBuilder` (advisory → MKOverlay, altitude filtering)
- `MapAeronautical.swift` — waypoint/airway/airspace rendering: annotations, polylines, airspace category colors

**Flights** — plan/file/fly workflow:
- `FlightsHomeView.swift` → `FlightDetailView.swift` (hub per flight)
- `FlightPlanFormView.swift` — ICAO plan editor; `FlightPlanCodec` maps SwiftData `Flight` ↔ `ICAOFlightPlan`
- `FilingAssistView.swift` — assisted-filing handoff to 1800wxbrief (tap-to-copy fields)
- `NavLogView.swift` — rendered navlog from FBFlightPlan's `NavLog`
- `ClearanceEntryView.swift`, `AircraftListView.swift`, `DocumentsSection.swift` (doc scanner via VisionKit)

**Airports** — `AirportsHomeView` (search) → `AirportDetailView` → `WeatherSection`, `PlatesSection`, `PlateViewerView` (PDF)

**Downloads** — `DownloadsHomeView.swift` + `FreshnessBadge` (AIRAC cycle status)

**Settings** — `SettingsHomeView.swift` (thin)

## Shared package (`Packages/FlightBagCore/`)

Four targets, dependency order `FBModels ← FBFlightPlan / FBProviders`; `FBGDL90` standalone:

- **FBModels** — zero-dep domain types: `Airport`, `Airspace`, `Advisory`, `Weather`, `Coordinate`, `AltitudeBand`, `DataCycle` (AIRAC math), `DataAuthority`, `DownloadManifest`, `PlateMetadata`
- **FBFlightPlan** — `ICAOFlightPlan`, `FlightPlanValidator` (same rules client+server — the package's reason to exist), `RouteParser` (needs a `WaypointResolving`), `NavLog`, `NavMath`
- **FBProviders** — `HTTPGetting` (injected transport) + protocols (`WeatherProvider`, `NotamProvider`, `PlateProvider`, `FilingService`) and FAA impls: `AviationWeatherGovProvider`, `TFRProvider`, `AirspaceProvider`, `WindsAloftProvider`, `AdvisoryProviders`
- **FBGDL90** — `GDL90Deframer` + `GDL90Message`: pure byte-level ADS-B decoding, no sockets

Tests live in `Packages/FlightBagCore/Tests/` with JSON fixtures under
`FBProvidersTests/Fixtures/`. These run fine locally (`swift test` in the
package dir) — the XCUITest ban applies only to the app's UI tests.

## Server (`Server/`)

- `routes.swift` — `/v1/manifest` (download manifest, products TBD) and `/v1/airports/:id/weather` (cached METAR/TAF proxy)
- `Commands/IngestCommands.swift` — CLI entry points: `ingest-nasr`, `ingest-dtpp`, `build-manifest`
- `Ingest/` — `NASRIngestor` (~380 ln, FAA NASR CSV → sqlite), `DTPPIngestor` (plates), `AeroDatabaseBuilder` (builds per-cycle `aero.sqlite`), `TilePipeline` (chart tiles → MBTiles), `CSVTable` (parsing helper)

## Where to start for common tasks

| Task touches… | Read first |
|---|---|
| Map layers / overlays | `MapLayersState.swift`, then `EFBMapView.swift` Coordinator |
| Advisory display (TFR/SIGMET) | `MapAdvisories.swift`, `AdvisoryStore.swift`, FBModels `Advisory` |
| Airport data / search | `AeroDatabase.swift` |
| Flight planning / validation | FBFlightPlan target, `FlightPlanFormView.swift` |
| Weather | `WeatherStore.swift`, `AviationWeatherGovProvider.swift` |
| New data in `aero.sqlite` | `AeroDatabaseBuilder.swift` (server) **and** `AeroDatabase.swift` (app) — schema must match |
| Downloads / cycles | FBModels `DataCycle` + `DownloadManifest`, `DownloadsHomeView.swift` |
