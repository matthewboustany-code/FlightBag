# FlightBag Code Map

File-level guide for navigating the codebase without reading everything.
Companion to [architecture.md](architecture.md), which records the *why*;
this records the *where*. Regenerate when the layout shifts (line counts
are approximate as of 2026-07-18; ~18,700 lines of Swift total).

## Top level

| Path | What it is |
|---|---|
| `FlightBag/` | iOS/iPadOS app target (SwiftUI + some UIKit/MapKit) |
| `Packages/FlightBagCore/` | Shared SPM package, Linux-compatible, used by app and server |
| `Server/` | Vapor 4 backend: `/v1/` API + AIRAC-cycle ingestion commands |
| `FlightBagTests/`, `FlightBagUITests/` | App-target tests. **Never run XCUITests locally** — they freeze this Mac; verify via launch-arg hooks + `simctl` screenshots (see below) |

## Verifying without XCUITests

Launch args seed deterministic state for `xcrun simctl` screenshots:

| Arg | Effect |
|---|---|
| `-initialTab map\|airports\|flights\|downloads\|settings` | opening tab |
| `-hasAcknowledgedDisclaimer YES` | skip the first-run legal gate |
| `-mapDemoSpan N` / `-mapDemoFollow` / `-mapDemoChart` / `-mapDemoPanel` | map framing, follow mode, chart kind, layers panel |
| `-mapDemoRadar` / `-mapDemoRadarSource internet\|adsb` | radar layer + source |
| `-mapDemoAdvisories` / `-mapDemoAltitudeFilter N` / `-mapDemoAero` | advisory + aeronautical layers |
| `-mapDemoSkipLocation YES` | skip the location prompt, which otherwise sits modally over the map |
| `-adsbDemoSeed YES` | seed traffic targets + a synthetic NEXRAD cell, no receiver needed |
| `-airportsDemoOpen KAUS` | deep-link to an airport detail page |
| `-weatherDemoOffline YES` | failing weather provider, to exercise cached/FIS-B paths |
| `-flightsDemoSeed YES -flightsDemoScreen plan\|filing\|navlog\|map` | flights workflow |
| `-serverBaseURL http://127.0.0.1:8080` | point ManifestClient/downloads at a local Vapor server |
| `-downloadsDemoSeed YES` / `-downloadsDemoOpen US-TX` | fake manifest + download states; deep-link a region detail |
| `-downloadsDemoAutostart US-TX` | really download a region's every published kind (needs `-serverBaseURL`) |
| `-mapDemoChart none` | deselect the chart layer (e.g. to see the offline basemap alone) |
| `-mapDemoInspect KAUS` | open the non-modal map info panel on an airport |
| `-mapDemoInspectAdvisories YES` | open the info panel with two synthetic advisories |
| `-mapDemoPlate KAUS` | pin the airport's first approach plate to the map (downloads it; needs internet) |
| `-mapDemoPlateKind apd` | with `-mapDemoPlate`: pin the airport diagram instead (runway-matched georef) |
| `-mapDemoProcedure KAUS:AEROZ2` | draw a SID/STAR's branches from the CIFP tables |
| `-mapDemoRoute YES` / `-mapDemoRouteEditor YES` | show the KAUS→KDAL demo route; also open the route editor panel |
| `-mapDemoRuler YES` | show the two-finger ruler HUD at fixed points (touches can't be scripted) |
| `-weatherShowDecoded YES` | start the airport weather section in Decoded mode |

For live ADS-B behavior, run `swift run gdl90sim` (in `Packages/FlightBagCore`)
alongside the app. Note the simulator persists `adsbEnabled`; if the receiver
reads "Off", run
`xcrun simctl spawn booted defaults write Me.FlightBag adsbEnabled -bool YES`
(editing the plist directly is clobbered by `cfprefsd`).

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
- `ChartStore.swift` — discovers downloaded MBTiles chart sets (`ChartSet`) and offline basemaps (`basemap_*` prefix); per-tree byte counts
- `PlateStore.swift` — actor; downloads/caches terminal procedure PDFs
- `DownloadCenter.swift` — `@MainActor @Observable` region-download orchestrator: manifest state, per-product phases, sha256 verify + install into `cycles/{cycle}/…`, refcounted region delete, old-cycle eviction; persists intent/facts in `downloads/state.json`; `chartsVersion` counter drives map/storage refresh
- `DownloadService.swift` — background `URLSession` (`Me.FlightBag.downloads`): resume data, relaunch reattach via `taskDescription` = product id; AppDelegate in `FlightBagApp.swift` catches `handleEventsForBackgroundURLSession`
- `ManifestClient.swift` — `ServerConfig` (UserDefaults `serverBaseURL`) + `/v1/manifest` fetch with offline JSON cache
- `ZipExtractor.swift` — minimal zip reader (stored/deflate, no zip64) for per-state plate bundles
- `PlateGeoreference.swift` — parses the geospatial viewport FAA embeds in IAP PDFs (`/VP` → BBox + GPTS/LPTS; registration points sit on an inset 0.1–0.9 ring, so corners come from an affine fit) + `PlateRasterizer` (BBox region → ≤2048px CGImage)
- `AirportDiagramGeoreference.swift` — georeferences APDs (which have NO embedded georef): CGPDFScanner harvests filled vector polygons → PCA oriented-box runway candidates (aspect ≥8, collinear merge) → matched to NASR `runway_end` coords by scale-free length/angle (parallel-runway permutations resolved by residual) → 4-DOF similarity fit; RMS ≤ 20 m gate, nil on any doubt. `matcherVersion` invalidates the resolver cache
- `ApproachFixGeoreference.swift` — georeferences military (DoD) IAPs, which also lack embedded georef: detects planview RNAV waypoint stars (spike-ring polygon signature; DoD text is unextractable so it's geometry-only) → north-up-constrained RANSAC similarity registration against NASR fixes/navaids/runway thresholds (unknown correspondence). Gates: ≥5 inliers, RMS ≤ 1 pt·scale, |rot| ≤ 1.5°, 40–500 m/pt; TAA/MSA decorative stars fall out as outliers; TACAN/ILS plates (no stars) → nil. ~1 s once per plate, then cached
- `PlateGeoreferenceResolver.swift` — the one answer to "can this plate pin to the map": embedded parse first (IAPs), APD runway-matcher fallback, military-IAP star-registration fallback, JSON cache incl. negative results (Application Support/FlightBag/plates/georef-cache.json). DPs/STARs stay nil → "Show on Map" disabled
- `WeatherStore.swift` — actor; METAR/TAF fetch + cache (`StationWeather`)
- `AdvisoryStore.swift` — fetches TFR/SIGMET/G-AIRMET via FBProviders
- `AirspaceStore.swift` — loads airspace polygons for map viewport
- `PositionSource.swift` — `PositionSource` protocol + `CoreLocationPositionSource`; `OwnshipPosition`
- `GDL90Receiver.swift` — the ADS-B entry point: `GDL90UDPListener` (NWListener on UDP 4000, per-endpoint deframer, decodes on its own queue) + `GDL90Receiver` (`@MainActor @Observable`; connection state machine, 1 Hz health/aging tick, FIS-B product counters, sinks for every consumer below)
- `GDL90PositionSource.swift` — `GDL90PositionSource` (ADS-B ownship, NIC/heartbeat gated) + `CompositePositionSource` (ADS-B preferred, CoreLocation fallback) — **this is what views should read**, via `AppEnvironment.positionSource`
- `TrafficStore.swift` — live traffic keyed by address, 30 s age-out, ownship-echo suppression
- `FISBRadarStore.swift` — NEXRAD mosaic from uplink blocks, 10-min expiry

### Features (`Features/`)
**Map** — the most complex feature; MapKit, not SwiftUI Map:
- `MapHomeView.swift` (~365 ln) — SwiftUI host: layer pickers, search, `MapInspection` state
- `MapInfoPanel.swift` — non-modal info card over the map (airport detail / tapped advisories); bottom card on compact, floating side card on iPad — replaced the old blocking sheets so the map stays scrubbable
- `PlateOverlay.swift` — `PlateOverlay` + `PlateOverlayRenderer`: a rasterized approach plate pinned to its geographic footprint (affine from 3 corners), opacity via the shared `overlayAlphas` plumbing; active plate lives on `AppEnvironment.activePlateOverlay`, opacity on `MapLayersState.plateOpacity`
- `RouteEditorPanel.swift` — `RouteWaypointAnnotation`/-`View` (labeled markers, tintable: magenta route / blue procedure) + `ProcedurePolyline` tag class + the non-modal route editor card (delete/reorder/add, edits write back to `AppEnvironment.activeMapRoute`; `ActiveMapRoute` carries identified points, airway intermediates tagged `via`)
- SID/STAR vector overlays: `ActiveMapProcedure` (AppEnvironment; branches = common + every transition, assembled from `AeroDatabase.procedureLegs`) → `Coordinator.syncProcedure` draws dashed-blue polylines + deduped fix markers; entry via `ProceduresSection` (Airports) or `-mapDemoProcedure`. Rasters are NOT georeferenced for SIDs/STARs (not to scale) — this is the deliberate alternative
- `MapRuler.swift` — `TwoFingerHoldGestureRecognizer` (two fingers held ~0.35 s; loses to pinch if they move) + `RulerHUDView` (screen-space dashed line + distance/course readout via NavMath; zoom/rotate suspended while measuring)
- `EFBMapView.swift` (~510 ln) — `UIViewRepresentable` wrapping `MKMapView`; `Coordinator` owns all delegate logic, annotations (airport/waypoint/ownship), overlay z-ordering, tap handling
- `MapLayersState.swift` — `ChartKind` (VFR/IFR-low/IFR-high) + observable toggle state for all layers
- `MBTilesOverlay.swift` — `MKTileOverlay` reading local MBTiles via GRDB
- `StreamingChartOverlay.swift` — FAA tile streaming with over-zoom (uses `TileResampler.swift`)
- `MapAdvisories.swift` — `AdvisoryCategory`, `AdvisoryPolygon`, `AdvisoryOverlayBuilder` (advisory → MKOverlay, altitude filtering)
- `MapAeronautical.swift` — waypoint/airway/airspace rendering: annotations, polylines, airspace category colors
- `MapTraffic.swift` — `TrafficAnnotation` + `TrafficAnnotationView` (track-rotated chevron, on-ground square, callsign/relative-altitude data block)
- `FISBRadarOverlay.swift` — `FISBRadarOverlay` (world rect, lock-guarded mosaic snapshot) + `FISBRadarRenderer` (draws only intersecting bins; 8-level NEXRAD ramp)

**Flights** — plan/file/fly workflow:
- `FlightsHomeView.swift` → `FlightDetailView.swift` (hub per flight)
- `FlightPlanFormView.swift` — ICAO plan editor; `FlightPlanCodec` maps SwiftData `Flight` ↔ `ICAOFlightPlan`
- `FilingAssistView.swift` — assisted-filing handoff to 1800wxbrief (tap-to-copy fields)
- `NavLogView.swift` — rendered navlog from FBFlightPlan's `NavLog`
- `ClearanceEntryView.swift`, `AircraftListView.swift`, `DocumentsSection.swift` (doc scanner via VisionKit)

**Airports** — `AirportsHomeView` (search) → `AirportDetailView` → `WeatherSection` (raw/decoded toggle backed by `WeatherDecoding.swift` — METAR from parsed fields, TAF tokenized group-by-group), `PlatesSection`, `PlateViewerView` (PDF)

**Downloads** — `DownloadsHomeView.swift` (region rows, storage split, `FreshnessBadge`, `productFreshness` honoring 56-day IFR expirations) → `RegionListView.swift` (manifest-driven state picker) → `RegionDetailView.swift` (chart-type toggles, per-product progress/pause/resume, refcount-aware delete)

**Settings** — `SettingsHomeView.swift` (thin)

## Shared package (`Packages/FlightBagCore/`)

Four targets, dependency order `FBModels ← FBFlightPlan / FBProviders`; `FBGDL90` standalone:

- **FBModels** — zero-dep domain types: `Airport`, `Airspace`, `Advisory`, `Weather`, `Coordinate`, `AltitudeBand`, `DataCycle` (AIRAC math), `DataAuthority` (decodes unknown values to `.unknown` so one unfamiliar authority can't fail a whole manifest), `DownloadManifest`, `PlateMetadata`, `Jurisdiction`/`RuleSet` (ICAO-prefix → country → rules), `UnitPreferences` (display-only conversion; storage stays hPa/SM/ft/NM/kt)
- **FBFlightPlan** — `ICAOFlightPlan`, `FlightPlanValidator` (same rules client+server — the package's reason to exist), `RouteParser` (needs a `WaypointResolving`), `NavLog`, `NavMath`
- **FBProviders** — `HTTPGetting` (injected transport) + protocols (`WeatherProvider`, `NotamProvider`, `PlateProvider`, `FilingService`) and FAA impls: `AviationWeatherGovProvider`, `TFRProvider`, `AirspaceProvider`, `WindsAloftProvider`, `AdvisoryProviders`
- **FBGDL90** — `GDL90Deframer` + `GDL90Message`: pure byte-level ADS-B decoding, no sockets
- **FBFISB** — UAT/FIS-B uplink decoding, fed by GDL90 0x07 payloads: `UATUplinkFrame` (ground uplink header + info frames) → `FISBAPDU` (product ID, time options, segmentation) → `FISBProduct`: `DLAC` 6-bit text → `FISBTextProduct` (METAR/TAF/…), and `NEXRADGlobalBlock` (RLE bins, empty-block bitmaps, `NEXRADBlockGeometry` block/bin → lat/lon). `FISBEncoding` mirrors each layer for tests and `gdl90sim`.

There is also a **`gdl90sim`** executable target (`swift run gdl90sim`) — a
hardware-free GDL90 receiver simulator that unicasts a synthetic scene
(ownship circuit at KAUS, traffic, DLAC METAR/TAF, drifting NEXRAD cell)
to `127.0.0.1:4000`. Flags: `--host --port --no-gps --stop-after --traffic`.
It's the main way to exercise ADS-B end-to-end.

Tests live in `Packages/FlightBagCore/Tests/` with JSON fixtures under
`FBProvidersTests/Fixtures/`. These run fine locally (`swift test` in the
package dir) — the XCUITest ban applies only to the app's UI tests.

## Server (`Server/`)

- `routes.swift` — `/v1/manifest` (serves `Public/artifacts/manifest.json`, empty fallback) and `/v1/airports/:id/weather` (cached METAR/TAF proxy); JSON wire format is ISO8601 (set in `configure.swift`, which also mounts `FileMiddleware` over `Public/` — range requests included, so background downloads resume)
- `Commands/IngestCommands.swift` — CLI entry points: `ingest-nasr` (which also pulls worldwide OurAirports data unless `FLIGHTBAG_GLOBAL_AIRPORTS=0`), `ingest-ourairports`, `ingest-dtpp`, `ingest-tiles` (`--set vfr|ifr-low|ifr-high`, `--chart`/`--panel`), `ingest-basemap`, `bundle-plates --region US-XX --db aero.sqlite`, `build-manifest --base-url`
- `Ingest/ARINC424.swift` + `Ingest/CIFPIngestor.swift` — FAA CIFP (ARINC 424) → `procedure`/`procedure_leg` tables (schema v3): fixed-width PD/PE parsing (fixture-tested against real lines), fix index from EA/PC/PG/D/DB records, coordinates resolved at ingest. `ingest-cifp` command (`--input` for manual FAACIFP18); runs inside `ingest-all` after DTPP
- `Commands/IngestAllCommand.swift` — `ingest-all`: the scheduled-job orchestrator. Picks the target cycle itself (HEAD-probes whether the FAA published the next one), no-ops via a `{cycle}/.complete` marker, skips artifacts that already exist (rerun = resume), runs db → tiles → basemap → plates → manifest, and rebuilds the manifest when the calendar rolls into a pre-built cycle. Scope comes from `FLIGHTBAG_*` env vars (see `Server/.env.example`); the db always builds, charts are opt-in
- `Ingest/` — `NASRIngestor` (~380 ln, FAA NASR CSV → sqlite), `DTPPIngestor` (plates), `AeroDatabaseBuilder` (builds per-cycle `aero.sqlite`), `TilePipeline` (`Source`: sectional / enroute low+high / Natural Earth basemap → MBTiles; enroute editions are 56-day, get `.expires` sidecars and `resolveEditionCycle`), `PlateBundler` (per-state plate zips, `{airportId}/{pdfName}` layout matching PlateStore), `ManifestBuilder` (artifact tree → manifest: sha256 sidecar cache, next-cycle + carry-forward), `ChartCatalog` (regions + sectional→state fallback table), `RegionBounds` (MBTiles `bounds` ∩ state bboxes → `regionIds`), `CSVTable` (parsing helper)
- Artifact layout: `Public/artifacts/{cycle}/{tiles|plates|basemap|db}/…` + `manifest.json` (gitignored; maps 1:1 to object-store keys later)
- Deployment: `Server/Dockerfile` (multi-stage; one image = serve + ingest, GDAL/zip/unzip in runtime stage; build context is the **repo root** for the FlightBagCore path dep), `Server/docker-compose.yml` (`server` service + `ingest` behind a compose profile), `Server/.env.example` (all `FLIGHTBAG_*` config, notably `FLIGHTBAG_BASE_URL` baked into manifest URLs), `Server/scripts/ingest-cron.sh` (daily cron trigger), `Server/DEPLOY.md` (NAS bring-up guide). Not yet exercised by a real Docker build — no container runtime on the dev Mac

## Where to start for common tasks

| Task touches… | Read first |
|---|---|
| Map layers / overlays | `MapLayersState.swift`, then `EFBMapView.swift` Coordinator |
| Advisory display (TFR/SIGMET) | `MapAdvisories.swift`, `AdvisoryStore.swift`, FBModels `Advisory` |
| Airport data / search | `AeroDatabase.swift` |
| Flight planning / validation | FBFlightPlan target, `FlightPlanFormView.swift` |
| Weather | `WeatherStore.swift`, `AviationWeatherGovProvider.swift` |
| Anything ADS-B (traffic, ownship, FIS-B) | `GDL90Receiver.swift` first — every consumer hangs off its sinks, wired in `AppEnvironment.init` |
| GDL90/FIS-B bit layouts | FBGDL90 / FBFISB targets; drive with `swift run gdl90sim` |
| Ownship position | `GDL90PositionSource.swift` (`CompositePositionSource` is the one views read) |
| New data in `aero.sqlite` | `AeroDatabaseBuilder.swift` (server) **and** `AeroDatabase.swift` (app) — schema must match |
| Units / non-US weather forms | FBModels `UnitPreferences` + `Jurisdiction`, app-side `UnitSettings.swift`, `WeatherDecoding.swift` |
| Worldwide airport/navaid data | server `OurAirportsIngestor.swift` (NASR stays authoritative for the US; see `coveredCountries`) |
| "Why is this feature missing abroad?" | FBModels `Capability` + `RuleSet.capabilities`, app-side `CapabilityNotice.swift` |
| Worldwide airspace | `OpenAIPAirspaceProvider` (CC BY-NC, needs a key; `AirspaceStore` picks it by viewport centre) |
| Downloads / cycles | FBModels `DataCycle` + `DownloadManifest`/`Region`, `DownloadCenter.swift`, `DownloadsHomeView.swift` |
| Chart-region downloads end-to-end | server `ManifestBuilder`/`ChartCatalog` → app `ManifestClient` → `DownloadCenter` → `ChartStore` (map picks tiles up via `chartsVersion`) |
| Deploying / operating the data server | `Server/DEPLOY.md`, then `docker-compose.yml` + `IngestAllCommand.swift` |
