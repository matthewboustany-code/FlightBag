# FlightBag Architecture

Decisions locked at project start (2026-07-12). The full phased plan lives in
the project history; this records the load-bearing choices.

## Layout

- `FlightBag/` — iOS/iPadOS app (SwiftUI). Features → Services → FlightBagCore.
- `Packages/FlightBagCore/` — shared SPM package, four Linux-compatible targets:
  - `FBModels` — domain types, API DTOs, AIRAC `DataCycle` math. Zero dependencies.
  - `FBFlightPlan` — ICAO FPL model, `FlightPlanValidator` (identical rules on
    client and server — the core reason this package exists), route parsing, nav math.
  - `FBProviders` — provider protocols + FAA implementations, transport-injected
    via `HTTPGetting`.
  - `FBGDL90` — pure byte-level GDL90/ADS-B decoding. No sockets; the app owns
    the UDP listener.
  - `FBFISB` — UAT/FIS-B uplink decoding (ground uplink frames, APDUs, DLAC
    text, NEXRAD global blocks). Also socket-free; fed by `FBGDL90`'s 0x07
    payloads. Encode helpers here back the tests and the `gdl90sim` tool.
- `Server/` — Vapor 4 backend. API under `/v1/`, ingestion pipelines as
  commands (`ingest-nasr`, `ingest-dtpp`, `build-manifest`).

## Key decisions

| Decision | Choice | Why |
|---|---|---|
| Filing | **Assisted filing** ships in Phase 3: full ICAO plan + validation + navlog in-app, then a zero-friction handoff to 1800wxbrief (per-field tap-to-copy, open-website button). Leidos LMFS integration is a fast-follow behind the same `FilingService` protocol | Vendor onboarding (email R-FFSP-WebServicesSupport@leidos.com, lab testing, SP-authorization listing) is free but has an uncontrollable timeline for a solo dev; nothing in the roadmap waits on it |
| Persistence (aviation data) | GRDB/SQLite, read-only per-cycle `aero.sqlite` built by server ingestion | FTS5 search, R*Tree spatial queries, atomic cycle swap; SwiftData can't do any of that |
| Persistence (user data) | SwiftData, CloudKit-safe schema (defaults, optional relationships, no uniques) | Enables iCloud private-db sync later with no migration |
| Map | MKMapView + MKTileOverlay reading local MBTiles via GRDB | Fully offline raster overlays without an embedded HTTP server; MapLibre is the named fallback |
| Data scope | Worldwide thin layer (OurAirports, public domain) over authoritative US/FAA data; everything tagged `DataAuthority` | International providers plug in via registration, not UI surgery |
| Units | Canonical storage (hPa, SM, ft, NM, kt); `UnitPreferences` converts only for display, `Jurisdiction` picks the default | A preference must never rewrite what an observation said — wind stays in knots, the ICAO reporting unit, everywhere |
| Rules vs. provenance | `DataAuthority` = who published a row; `Jurisdiction`/`RuleSet` = whose rules apply there | The two diverge as soon as data stops being FAA-only: OurAirports is the *authority* for a German aerodrome, EASA its *jurisdiction* |
| Offline | Hard requirement from Phase 1 | Cockpit connectivity assumption is zero |

## Operational cadence

All chart/plate/database artifacts are versioned by 28-day AIRAC cycle
(`DataCycle`). Ingestion must run every cycle; the FAA publishes the next
cycle ~20 days early, so the app downloads ahead and swaps atomically at the
effective instant. UI shows freshness badges everywhere.

## Long-lead external dependencies (start early!)

1. **Leidos LMFS vendor onboarding** — send the inquiry email
   (R-FFSP-WebServicesSupport@leidos.com) early, but treat direct filing as a
   fast-follow, not a Phase 3 blocker: assisted filing (handoff to
   1800wxbrief) is the shipping path. Registering as a business entity (LLC)
   strengthens the ask and is worth considering for liability regardless.
2. **FAA NOTAM API key** — free registration at external.faa.gov.
3. **Apple multicast entitlement** (`com.apple.developer.networking.multicast`)
   — required only to receive *broadcast* GDL90. Mainstream receivers
   (Stratux, Sentry) unicast to each DHCP client, which needs no
   entitlement, so ADS-B In ships without it; only broadcast-only units
   are affected. `FlightBag/FlightBag.entitlements` is deliberately empty:
   add the key **after** Apple grants the request, since a profile without
   the grant fails to sign a build that declares it.
