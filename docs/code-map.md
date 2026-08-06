# FlightBag Code Map

File-level guide for navigating the codebase without reading everything.
Companion to [architecture.md](architecture.md), which records the *why*;
this records the *where*. Regenerate when the layout shifts (line counts
are approximate as of 2026-08-06; ~28,200 lines of Swift total).

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
| `-mapDemoCenter "44.5,-105.6"` | frame the map somewhere other than the default (chart work happens where the charts are) |
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
| `-notamsDemoSeed YES` | seed KAUS NOTAMs (two with geometry, one without), so the NOTAM UI works with no server and no FAA credentials |
| `-mapDemoNotams YES` | enable the NOTAM map layer; needs a route (`-mapDemoRoute`) to have anything to draw |

For live ADS-B behavior, run `swift run gdl90sim` (in `Packages/FlightBagCore`)
alongside the app. Note the simulator persists `adsbEnabled`; if the receiver
reads "Off", run
`xcrun simctl spawn booted defaults write Me.FlightBag adsbEnabled -bool YES`
(editing the plist directly is clobbered by `cfprefsd`).

### Chart rendering, with real charts

Chart bugs are geometry bugs: the demo seed has no tiles, so anything about
collars, seams, or which layer wins has to be checked against real FAA
sheets. Sideload them straight into the app's container — no download UI, no
manifest:

```bash
# 1. A pair of *neighbouring* sectionals, from the deployed server
curl -O http://192.168.1.69:8080/artifacts/2607/tiles/Cheyenne_sectional.mbtiles
curl -O http://192.168.1.69:8080/artifacts/2607/tiles/Omaha_sectional.mbtiles

# 2. Into the container, with the sidecars an install would have written
TILES="$(xcrun simctl get_app_container booted Me.FlightBag data)/Library/Application Support/FlightBag/cycles/2607/tiles"
mkdir -p "$TILES" && cp *_sectional.mbtiles "$TILES"
for f in "$TILES"/*.mbtiles; do printf vfrSectional > "$f.kind"; printf faa > "$f.authority"; done

# 3. Frame the seam between them
xcrun simctl launch --terminate-running-process booted Me.FlightBag \
  -initialTab map -hasAcknowledgedDisclaimer YES -mapDemoSkipLocation YES \
  -mapDemoSpan 3 -mapDemoCenter "42.0,-101.6"
```

Neighbouring matters, and so does *which* neighbour: a sheet's legend panel
lies west of its own map area, over the chart next door, and the sets render
in name order — so the collar only paints over a neighbour whose name sorts
earlier (Omaha over Cheyenne, but not Billings over Great Falls). Chart
overlays are also rebuilt only when their key changes, and coverage is part
of that key, because detection lands a second or two after the chart does.

Collar detection writes a `.coverage` sidecar next to each `.mbtiles`.
Deleting them forces a re-detect on next launch; writing one by hand with
`"body": null` reproduces the pre-clipping render exactly, which is how to
get an honest before/after out of one build.

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
- `AeroDatabase.swift` (~630 ln, largest service) — GRDB read-only wrapper over per-cycle `aero.sqlite`. FTS5 search (`SearchResult`), `AirportDetail`, map queries (`MapWaypoint`, `AirwayLine`), airspace R*Tree lookups. Conforms to `WaypointResolving` for the route parser.
- `ChartStore.swift` — discovers downloaded MBTiles chart sets (`ChartSet`) and offline basemaps (`basemap_*` prefix); per-tree byte counts
- `ChartCoverage.swift` — `ChartCoverage` (where a tile set actually draws chart, as a per-column top/bottom mask in normalized Web Mercator) + `ChartCoverageDetector`, which finds an FAA sheet's map area inside its collar by growing a colour-dense region out of the tiles at ~z8 and tracing its edges. Cached in a `.coverage` sidecar beside the `.mbtiles`; nil `body` means "no collar found, draw the whole file"
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
- `NotamStore.swift` — actor; NOTAMs per airport, modelled on `WeatherStore`. Fetches only through the server proxy (NMS's OAuth credentials can't ship in the app), disk-caches last-good in `notam-cache.json`, folds in FIS-B uplink NOTAMs, and `briefing(for:)` fans out across a route's airports in bounded batches. Returns an `Availability` alongside the list so the UI can distinguish *no NOTAMs* from *no server* / *no credentials* / *unreachable* — a bare empty list would read as "nothing is wrong here". Also home to `FISBTextReport.toNotam()` (FBFISB is standalone and knows nothing of FBModels)
- `AdvisoryStore.swift` — fetches TFR/SIGMET/G-AIRMET via FBProviders
- `AirspaceStore.swift` — loads airspace polygons for map viewport
- `PositionSource.swift` — `PositionSource` protocol + `CoreLocationPositionSource`; `OwnshipPosition`
- `GDL90Receiver.swift` — the ADS-B entry point: `GDL90UDPListener` (NWListener on UDP 4000, per-endpoint deframer, decodes on its own queue) + `GDL90Receiver` (`@MainActor @Observable`; connection state machine, 1 Hz health/aging tick, FIS-B product counters, sinks for every consumer below)
- `GDL90PositionSource.swift` — `GDL90PositionSource` (ADS-B ownship, NIC/heartbeat gated) + `CompositePositionSource` (ADS-B preferred, CoreLocation fallback) — **this is what views should read**, via `AppEnvironment.positionSource`
- `TrafficStore.swift` — live traffic keyed by address, 30 s age-out, ownship-echo suppression
- `FISBRadarStore.swift` — NEXRAD mosaic from uplink blocks, 10-min expiry

### Features (`Features/`)
**Map** — the most complex feature; MapKit, not SwiftUI Map:
- `MapHomeView.swift` (~660 ln) — SwiftUI host: layer pickers, search, `MapInspection` state
- `MapInfoPanel.swift` — non-modal info card over the map (airport detail / tapped advisories); bottom card on compact, floating side card on iPad — replaced the old blocking sheets so the map stays scrubbable
- `PlateOverlay.swift` — `PlateOverlay` + `PlateOverlayRenderer`: a rasterized approach plate pinned to its geographic footprint (affine from 3 corners), opacity via the shared `overlayAlphas` plumbing; active plate lives on `AppEnvironment.activePlateOverlay`, opacity on `MapLayersState.plateOpacity`
- `RouteEditorPanel.swift` — `RouteWaypointAnnotation`/-`View` (labeled markers, tintable: magenta route / blue procedure) + `ProcedurePolyline` tag class + the non-modal route editor card (delete/reorder/add, edits write back to `AppEnvironment.activeMapRoute`; `ActiveMapRoute` carries identified points, airway intermediates tagged `via`)
- SID/STAR vector overlays: `ActiveMapProcedure` (AppEnvironment; branches = common + every transition, assembled from `AeroDatabase.procedureLegs`) → `Coordinator.syncProcedure` draws dashed-blue polylines + deduped fix markers; entry via `ProceduresSection` (Airports) or `-mapDemoProcedure`. Rasters are NOT georeferenced for SIDs/STARs (not to scale) — this is the deliberate alternative
- `MapRuler.swift` — `TwoFingerHoldGestureRecognizer` (two fingers held ~0.35 s; loses to pinch if they move) + `RulerHUDView` (screen-space dashed line + distance/course readout via NavMath; zoom/rotate suspended while measuring)
- `EFBMapView.swift` (~980 ln) — `UIViewRepresentable` wrapping `MKMapView`; `Coordinator` owns all delegate logic, annotations (airport/waypoint/ownship), overlay z-ordering, tap handling
- `MapLayersState.swift` — `ChartKind` (VFR/IFR-low/IFR-high) + observable toggle state for all layers
- `MBTilesOverlay.swift` — `MKTileOverlay` reading local MBTiles via GRDB, clipped to the chart's `ChartCoverage` body (+ `ChartTileMask`, which re-cuts the tiles that straddle the neatline)
- `StreamingChartOverlay.swift` — FAA tile streaming with over-zoom (uses `TileResampler.swift`); sits *under* the downloaded sets to fill what they don't cover, and skips tiles a download paints in full
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

**Downloads** — `DownloadsHomeView.swift` (region rows, storage split, `FreshnessBadge`, `productFreshness` honoring 56-day IFR expirations; owns `DownloadsRoute`, the one route type for the whole stack) → `RegionListView.swift` (manifest-driven state picker: row tap opens the detail, the row's download button takes the whole region, "Select" multi-selects) → `RegionDetailView.swift` (chart-type toggles, per-product progress/pause/resume, refcount-aware delete)

**Settings** — `SettingsHomeView.swift` (thin)

## Shared package (`Packages/FlightBagCore/`)

Four targets, dependency order `FBModels ← FBFlightPlan / FBProviders`; `FBGDL90` standalone:

- **FBModels** — zero-dep domain types: `Airport`, `Airspace`, `Advisory`, `Weather`, `Coordinate`, `AltitudeBand`, `DataCycle` (AIRAC math), `DataAuthority` (decodes unknown values to `.unknown` so one unfamiliar authority can't fail a whole manifest), `DownloadManifest` (`DownloadProduct.ContentKind` also owns the UI's names and ordering — `displayName` + `offeredPerRegion` — so adding a kind is one edit, not three), `PlateMetadata`, `Jurisdiction`/`RuleSet` (ICAO-prefix → country → rules), `UnitPreferences` (display-only conversion; storage stays hPa/SM/ft/NM/kt), `MagneticModel` (`WorldMagneticModel` — WMM2025 spherical-harmonic declination worldwide, with a validity window; coefficients in `WMM2025Coefficients.swift`, checked against NOAA's 100 published test values)
- **FBFlightPlan** — `ICAOFlightPlan`, `FlightPlanValidator` (same rules client+server — the package's reason to exist), `RouteParser` (needs a `WaypointResolving`), `NavLog` (legs carry true *and* magnetic course; variation is computed per leg from the WMM, not read off the departure airport), `NavMath`
- **FBProviders** — `HTTPGetting` (injected transport) + protocols (`WeatherProvider`, `NotamProvider`, `PlateProvider`, `FilingService`) and FAA impls: `AviationWeatherGovProvider`, `TFRProvider`, `AirspaceProvider`, `WindsAloftProvider`, `AdvisoryProviders`, `FAANotamProvider`. The last is the only one that authenticates, and the only one that is rate-limited: `NMSTokenStore` (actor; concurrent callers join one in-flight exchange, refreshed 60 s early) and `NMSRequestPacer` (actor; holds every outbound call — token exchange included — to ~1/s for Apigee's spike arrest, one retry on 429). Its wire decoding is deliberately forgiving because the FAA types the GeoJSON feature body as an untyped map: values decode whether or not they are quoted, non-Point geometries are dropped rather than throwing, and a feature that yields no id or text is skipped instead of failing the response. The fixtures are the spec's published shapes, not invented ones — `nms_notams_faa_sample.json` is the FAA's own example verbatim
- **FBGDL90** — `GDL90Deframer` + `GDL90Message`: pure byte-level ADS-B decoding, no sockets
- **FBFISB** — UAT/FIS-B uplink decoding, fed by GDL90 0x07 payloads: `UATUplinkFrame` (ground uplink header + info frames) → `FISBAPDU` (product ID, time options, segmentation) → `FISBProduct`: `DLAC` 6-bit text → `FISBTextProduct` (METAR/TAF/NOTAM/…; products **8 and 413** share one decoder because they share the DLAC record format — the leading token says which kind each record is), and `NEXRADGlobalBlock` (RLE bins, empty-block bitmaps, `NEXRADBlockGeometry` block/bin → lat/lon). `FISBEncoding` mirrors each layer for tests and `gdl90sim`.

There is also a **`gdl90sim`** executable target (`swift run gdl90sim`) — a
hardware-free GDL90 receiver simulator that unicasts a synthetic scene
(ownship circuit at KAUS, traffic, DLAC METAR/TAF, drifting NEXRAD cell)
to `127.0.0.1:4000`. Flags: `--host --port --no-gps --stop-after --traffic`.
It's the main way to exercise ADS-B end-to-end.

Tests live in `Packages/FlightBagCore/Tests/` with JSON fixtures under
`FBProvidersTests/Fixtures/`. These run fine locally (`swift test` in the
package dir) — the XCUITest ban applies only to the app's UI tests.

## Server (`Server/`)

- `routes.swift` — `/v1/manifest` (serves `Public/artifacts/manifest.json`, empty fallback), `/v1/airports/:id/weather` (cached METAR/TAF proxy) and `/v1/airports/:id/notams` (FAA NMS proxy, `NotamCache` at a 15-min TTL). The NOTAM route has three deliberate outcomes: no credentials → 200 with `configured: false`; upstream failure → **502**, never an empty 200, so the app falls back to its cache instead of concluding the airport is clear; otherwise the list. Credentials come from `FLIGHTBAG_NOTAM_CLIENT_ID`/`_SECRET` in `configure.swift`; JSON wire format is ISO8601 (set in `configure.swift`, which also mounts `FileMiddleware` over `Public/` — range requests included, so background downloads resume)
- `Commands/IngestCommands.swift` — CLI entry points: `ingest-nasr` (which also pulls worldwide OurAirports data unless `FLIGHTBAG_GLOBAL_AIRPORTS=0`), `ingest-ourairports`, `ingest-dtpp`, `ingest-tiles` (`--set vfr|ifr-low|ifr-high`, `--chart`/`--panel`), `ingest-basemap`, `bundle-plates --region US-XX --db aero.sqlite`, `build-manifest --base-url`
- `Ingest/ARINC424.swift` + `Ingest/CIFPIngestor.swift` — FAA CIFP (ARINC 424) → `procedure`/`procedure_leg` tables (schema v3): fixed-width PD/PE parsing (fixture-tested against real lines), fix index from EA/PC/PG/D/DB records, coordinates resolved at ingest. `ingest-cifp` command (`--input` for manual FAACIFP18); runs inside `ingest-all` after DTPP
- `Commands/IngestAllCommand.swift` — `ingest-all`: the scheduled-job orchestrator. Picks the target cycle itself (HEAD-probes whether the FAA published the next one), no-ops via a `{cycle}/.complete` marker, skips artifacts that already exist (rerun = resume), runs db → tiles → basemap → plates → manifest, and rebuilds the manifest when the calendar rolls into a pre-built cycle. Scope comes from `FLIGHTBAG_*` env vars (see `Server/.env.example`); the db always builds, charts are opt-in. The db step is NASR → OurAirports → `buildIndexes` → d-TPP → CIFP: the worldwide step has to sit between NASR (whose rows tell `coveredCountries` what to skip) and the index build (which is what makes it searchable)
- `Ingest/` — `NASRIngestor` (~380 ln, FAA NASR CSV → sqlite), `DTPPIngestor` (plates), `AeroDatabaseBuilder` (builds per-cycle `aero.sqlite`), `TilePipeline` (`Source`: sectional / enroute low+high / Natural Earth basemap → MBTiles; enroute editions are 56-day, get `.expires` sidecars and `resolveEditionCycle`), `PlateBundler` (per-state plate zips, `{airportId}/{pdfName}` layout matching PlateStore), `ManifestBuilder` (artifact tree → manifest: sha256 sidecar cache, next-cycle + carry-forward), `ChartCatalog` (regions + sectional→state fallback table), `RegionBounds` (MBTiles `bounds` ∩ state bboxes → `regionIds`), `CSVTable` (parsing helper)
- Artifact layout: `Public/artifacts/{cycle}/{tiles|plates|basemap|db}/…` + `manifest.json` (gitignored; maps 1:1 to object-store keys later)
- Deployment: `Server/Dockerfile` (multi-stage; one image = serve + ingest, GDAL/zip/unzip in runtime stage; build context is the **repo root** for the FlightBagCore path dep), `Server/docker-compose.yml` (`server` service + `ingest` behind a compose profile), `Server/.env.example` (all `FLIGHTBAG_*` config, notably `FLIGHTBAG_BASE_URL` baked into manifest URLs), `Server/scripts/ingest-cron.sh` (daily cron trigger), `Server/DEPLOY.md` (bring-up guide + the record of what has actually been built). Proven end to end: cycle 2608 was built full-scope on the Debian/Proxmox host and 2607 is served to the app over the LAN

## Where to start for common tasks

| Task touches… | Read first |
|---|---|
| Map layers / overlays | `MapLayersState.swift`, then `EFBMapView.swift` Coordinator |
| Advisory display (TFR/SIGMET) | `MapAdvisories.swift`, `AdvisoryStore.swift`, FBModels `Advisory` |
| Airport data / search | `AeroDatabase.swift` |
| Flight planning / validation | FBFlightPlan target, `FlightPlanFormView.swift` |
| Weather | `WeatherStore.swift`, `AviationWeatherGovProvider.swift` |
| NOTAMs | `NotamStore.swift` (app) and `FAANotamProvider.swift` (FBProviders: NMS, OAuth token store, ~1 req/s pacing). UI: `NotamSection.swift`, `NotamBriefingView.swift`, and the `.notam` branch of `MapAdvisories.swift`. The app never calls the FAA directly — everything goes through the server route. Changing the NMS wire decoding? Check the payload shapes against `Fixtures/nms_notams_faa_sample.json` first; the FAA's field names are not the ones you would guess |
| Anything ADS-B (traffic, ownship, FIS-B) | `GDL90Receiver.swift` first — every consumer hangs off its sinks, wired in `AppEnvironment.init` |
| GDL90/FIS-B bit layouts | FBGDL90 / FBFISB targets; drive with `swift run gdl90sim` |
| Ownship position | `GDL90PositionSource.swift` (`CompositePositionSource` is the one views read) |
| New data in `aero.sqlite` | `AeroDatabaseBuilder.swift` (server) **and** `AeroDatabase.swift` (app) — schema must match |
| Units / non-US weather forms | FBModels `UnitPreferences` + `Jurisdiction`, app-side `UnitSettings.swift`, `WeatherDecoding.swift`. Note `runwayLength` is its own dimension, not a follower of `altitude` — ICAO states fly feet and publish runways in metres |
| Worldwide airport/navaid data | server `OurAirportsIngestor.swift` (NASR stays authoritative for the US; see `coveredCountries`) |
| "Why is this row missing from the map/search?" | `airport.kind` (schema v5), not `site_type`. Each authority writes its own dialect into `site_type` — NASR `A`/`H`/`C`, OurAirports `large_airport`/`heliport` — so only `kind` is safe to filter on. FBModels `AirportKind`; app-side `AeroDatabase.landingFacilityPredicate` falls back to the old test on v4 databases |
| "Why is this feature missing abroad?" | FBModels `Capability` + `RuleSet.capabilities`, app-side `CapabilityNotice.swift` |
| Magnetic variation / magnetic courses | FBModels `MagneticModel.swift`; consumed by `NavLogBuilder` (per leg, at the planned departure date) and `AirportDetailView.magneticVariationRow`. Updating the model = drop in the next `WMM.COF` and change the epoch/validity |
| Worldwide airspace | `OpenAIPAirspaceProvider` (CC BY-NC, needs a key; `AirspaceStore` picks it by viewport centre) |
| Where a chart layer's tiles come from | FBModels `ChartSource` (manifest-carried: authority, tile template, zoom range, regions). `ChartKind` is now only a *category*. Built-in FAA descriptors exist solely as a pre-manifest fallback. Note the FAA VFR service starts at **z8** — zoomed out past that, undownloaded areas draw nothing, and always did |
| "A white block is covering my chart" / anything clipped | `ChartCoverage.swift`. The collar is detected from the tiles, cached in a `.coverage` sidecar, and applied by `MBTilesOverlay`; a nil `body` means "draw everything", which is the pre-2026-08 behaviour and the safe fallback whenever detection is unsure. Tuning constants (`cell`, `seedChroma`/`growChroma`, `insetCells`) were calibrated against real sectionals — change them and re-check against real ones, not the synthetic test sheet |
| Which chart layer wins where | `EFBMapView.syncOverlays` builds the chart group bottom-up: streaming first, then each downloaded set in name order, all above the basemap and below radar. `MapLayersState.streamChartGaps` is the pilot-facing switch; `StreamingChartOverlay` skips any tile a download paints in full |
| Adding a chart authority | server `ChartCatalog.chartSources` + `regions`, plus an ingestor. `OpenFlightMapsIngestor` is the simplest example — OFM publishes MBTiles directly, so ingest is a verified copy with no GDAL step |
| Source attribution | `DataAuthority.attribution`; carried to disk by DownloadCenter's `.authority` sidecar, read by `ChartStore`, rendered by `MapHomeView.attributionStrip`. Works offline by design — the licences do not lapse without a network |
| Downloads / cycles | FBModels `DataCycle` + `DownloadManifest`/`Region`, `DownloadCenter.swift`, `DownloadsHomeView.swift` |
| Chart-region downloads end-to-end | server `ManifestBuilder`/`ChartCatalog` → app `ManifestClient` → `DownloadCenter` → `ChartStore` (map picks tiles up via `chartsVersion`) |
| Deploying / operating the data server | `Server/DEPLOY.md`, then `docker-compose.yml` + `IngestAllCommand.swift` |
