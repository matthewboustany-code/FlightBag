# Deploying the FlightBag data server

The data server is one Docker image with two roles: the Vapor API +
artifact hosting (`serve`, the default), and the per-AIRAC-cycle chart
production pipeline (`ingest-all`). Everything is orchestrated by
[docker-compose.yml](docker-compose.yml) and configured through a `.env`
file — see [.env.example](.env.example).

## Current state

**Every stage of the pipeline is proven on Linux.** Cycle 2608 was built
full-scope on the production host — a Debian 13 / Proxmox Docker VM
(`debian4docker`, amd64, 4 cores / 8 GB) running Docker 29.7.1 and compose
v5.4.0 — from an empty artifact tree, on 2026-08-05:

| Stage | Result |
| :-- | :-- |
| Database (NASR + d-TPP + CIFP + OurAirports) | schema 5; 64 007 airports, 9 129 navaids, 24 046 plates, 4 010 CIFP procedures / 73 314 legs |
| VFR sectionals | 53 / 53, no failures |
| IFR enroute panels | 48 / 48 (36 low + 12 high), no failures |
| Basemap | Natural Earth, 251 MB |
| Plate bundles | 51 / 51 state regions, no failures |
| Manifest | 104 current + 52 next-cycle products, 19.4 GB |

Cycle 2607 was built the same way at a narrower scope (2 sectionals, US-TX
plates, basemap) and served end to end to the app.

The manifest split is worth understanding, because it looks wrong at first
glance. Charts resolve to their 56-day edition, which for 2608 is the one dated
under **2607** — so they are *current* products. The 2608 database and plate
bundles are 28-day and sit in `nextCycleProducts` until the calendar reaches the
cycle, at which point a run graduates them without rebuilding anything.

Everything is served over the LAN with matching `.sha256` and range requests
(`206 Partial Content`), which the app's download resume depends on. GDAL 3.8.4,
`unzip`/`zip`/`curl` are all on `PATH` in the runtime image.

The image also builds and serves on macOS/arm64 (Docker 29.6.2 / compose v5.3.1)
— that was the original development path, and it is worth remembering that
**macOS proves very little about Linux here**: every defect listed under "FAA
data and platform quirks" below was invisible on Darwin.

Band count is settled at **4** (RGBA) for both sectionals and enroute panels, so
`gdalwarp -dstalpha` is correctly treating the source alpha rather than adding a
fifth band, which the MBTILES driver would refuse. Verify with:

```sh
gdalinfo <artifacts>/<cycle>/tiles/<chart>.mbtiles | grep -c '^Band '
```

## FAA data and platform quirks

Five assumptions in this codebase turned out to be wrong the first time the
pipeline ran for real. They are listed because the pattern matters more than the
individual bugs: **the FAA's products are less uniform than they look, and a
static per-product assumption is usually the thing that breaks.** Prefer asking
the data.

### Charts are 56-day; the database is 28-day

VFR sectionals publish on a **56-day** cadence, exactly like IFR enroute panels.
On roughly half the 28-day AIRAC cycles there is no new chart edition and the
current one carries over. Cycle 2607 has a `07-09-2026` edition; the next is
`09-03-2026`; there is nothing at `08-06-2026` (cycle 2608).

Three places assumed sectionals were 28-day, and all three broke on 2608:

- **Cycle detection.** `resolveTargetCycle` probed a sectional URL to decide
  whether the FAA had published the next cycle. On an off cycle that 404s
  forever, so `ingest-all` silently kept targeting the current cycle — a daily
  cron would have sat on an expiring cycle and never rolled over. It now probes
  the **d-TPP metafile**, which is genuinely 28-day. NASR would work too, but
  `nfdc.faa.gov` answers **503 to HEAD** requests, so aeronav's metafile is the
  only usable HEAD probe. (Use a ranged GET to check NASR by hand.)
- **Edition resolution.** `resolveEditionCycle` only walked back a cycle for
  enroute sources, so an all-sectionals run against 2608 died on the first
  chart with `Chart download failed: HTTP 404`.
- **`.expires` sidecars.** Only written for enroute panels. A sectional whose
  edition lives under the prior cycle would have dropped out of the next
  cycle's manifest entirely.

`Source.isFiftySixDayEdition` now covers all three. The distinction that matters
is *dated FAA chart* vs the Natural Earth basemap — not VFR vs IFR.

### Not every chart is paletted

`gdal_translate -expand rgba` is valid only on a raster with a colour table.
VFR sectionals are 256-colour; **IFR enroute panels ship as straight RGB**
(Band 1 Red, 2 Green, 3 Blue) and the expand step fails on them with
`ERROR 1: Error : band 1 has no color table`. All 48 panels failed this way on
the first full-scope run.

The pipeline now asks `gdalinfo` whether band 1 has a colour table and expands
only when it does, rather than keying off the product type. Panels log
`Already RGB — skipping palette expansion`.

This one hid for a while because `runIngestProcess` truncated stderr with
`prefix(300)` and GDAL emits a ~290-character `EPSG:4269` warning on *every* FAA
chart — so the real error was cut off and 48 panels failed with nothing in the
log but a warning. It now reports the `ERROR` lines, or the tail.

### Withdrawn charts (DELETED_JOB)

Each cycle the FAA marks withdrawn charts with `useraction` `D` and the literal
sentinel `pdf_name` `DELETED_JOB.PDF` — 43 of them in 2607. That name ends in
`.PDF`, so the old suffix check let them through into the `plate` table, where
two things went wrong: bundling eventually requested one and got a 404, and the
app would have listed 43 charts that do not exist. They are now dropped at parse
time. Expect the plate count to be slightly *lower* than the metafile's record
count for this reason (24 047 vs 24 090 in 2607).

### The d-TPP 10 MB parser limit

On Linux, `XMLParser` is swift-corelibs-foundation's libxml2 wrapper, and it
never sets `XML_PARSE_HUGE`. libxml2 therefore enforces `XML_MAX_TEXT_LENGTH`
(10 000 000 bytes) and fails any larger document. The d-TPP metafile is ~16 MB,
so `parse()` returned false with `NSXMLParserInternalError` — reported at EOF,
*after* every element had already been delivered correctly. Darwin's
`NSXMLParser` has no such limit, which is why this never showed up on macOS.

The symptom is badly misleading: a Swift `Fatal error` + backtrace with
`Error Domain=NSXMLParserErrorDomain Code=1 "(null)"`, which reads like a
corrupt download. The metafile was fine — Python parsed it without complaint.
Threshold confirmed empirically with synthetic documents: 9 MB parses, 10 MB
does not, regardless of BOM, CRLF, or element count.

`DTPPMetafileParser.parse` now gates on whether the root element actually
closed rather than on `parse()`'s return value. A truncated or malformed file
never closes its root, so that stays a real failure.

**If another ingestor ever parses XML over 10 MB on Linux, it will hit this
same wall** — apply the same pattern rather than assuming a bad download.

### `FLIGHTBAG_REGIONS=all` means US states

Terminal procedures are an FAA d-TPP product, so only US states have them.
`ChartCatalog.regionIds` also carries the open flightmaps FIRs (`OFM-LOVV` and
friends), and handing one of those to `PlateBundler` is a hard error. `all` now
expands to plate-capable regions only. An explicit list naming a FIR still
errors, which is correct — that is a typo, not a scope choice.

## Failure and resume policy

A full-scope run is 100+ chart downloads and ~24 000 plate PDFs over several
hours. It is built to survive a bad artifact rather than discard the run:

- **Charts and plate regions accumulate failures.** Each is its own artifact and
  the manifest is generated from what is on disk, so a missing sectional is
  simply not offered — the app stays usable and the gap is visible. The run
  therefore continues to the end, writes the manifest, then reports every
  failure and exits nonzero.
- **`.complete` is withheld when anything failed.** That marker is what makes
  the next run a no-op, so withholding it is what makes the next cron run retry
  precisely the missing artifacts and nothing else.
- **Plate *bundles* are different**: a zip must never ship incomplete, because
  unlike a missing chart the gap is invisible from outside. `PlateBundler`
  therefore collects every bad plate in the region, then fails the region rather
  than writing a partial bundle, and **asserts completeness** — `fetched +
  cached` must equal the row count the database claims for that region.
- **Cached files are validated, not just counted.** A truncated PDF or chart zip
  left by an interrupted run (OOM kill, host suspend) is re-fetched rather than
  reused, so a bad cache heals itself instead of persisting across runs.
- **Downloads retry only what retrying fixes** — timeouts, resets, 5xx, 429.
  A 4xx is authoritative (edition resolution has already walked back a cycle by
  then) and fails immediately.
- **Payloads are sniffed** (`%PDF`, `PK`) so a 200-with-an-HTML-error-page is
  never written, and staged to a temp path then renamed so an interrupted run
  cannot leave a truncated file the next run treats as cached.

So the normal response to a partial run is simply to run it again.

## Platform notes

- **Linux Foundation gaps.** Every file under `Sources/App/Ingest/` carries the
  `#if canImport(FoundationNetworking)` guard, and all downloads go through
  `URLSession.data(for:)` rather than the async `download(from:)` family, whose
  swift-corelibs coverage is thinner. Both are deliberate — keep new ingestors
  to the same pattern.
- **GDAL** is shelled out to (`gdal_translate`/`gdalwarp`/`gdaladdo`, 3.8.4 in
  the image). `ingest-all` preflights the tools and logs the version before
  downloading anything, and skips that check when no charts are in scope.
- **Volume permissions.** The container runs as non-root `vapor` = **uid 999**.
  Bind-mounted host directories must be chowned to it; see step 2 below. The
  same applies in reverse when clearing artifacts by hand — the host user cannot
  delete uid-999 files, so go through a container:

  ```sh
  docker compose --profile ingest run --rm --entrypoint sh ingest \
    -c "rm -f /app/Public/artifacts/<cycle>/<path>"
  ```

- **Builds.** `swift package resolve` does long `git` fetches (vapor alone took
  ~8 min on a slow link). If the host restarts mid-build the CLI can hang
  indefinitely on an orphaned buildkit session — kill it and rerun, the fetch
  cache survives. Run long ingests detached (`setsid nohup … &`) so an SSH drop
  or a workstation reboot cannot take them down.

## Prerequisites

- Docker with the compose plugin (Container Manager on Synology, Apps on
  TrueNAS SCALE, etc. all provide it).
- Disk, measured on the 2608 full-scope build rather than estimated: sectionals
  and enroute panels run **~200–270 MB each** as MBTiles, plate bundles
  ~50–600 MB per state (Texas is the big one at 567 MB / 2 934 plates), basemap
  251 MB. **"Everything" is roughly 25–30 GB of artifacts per cycle**, plus a
  similar-sized workdir download cache that `pruneWorkCaches` trims to the
  current and previous cycle. Two cycles coexist during rollover, so budget
  ~80 GB to be comfortable.

  (An earlier revision of this doc guessed "100+ GB"; that was pessimistic by
  about 4×.)
- Memory: allow ~2 GB for ingest (chart zips are held in memory during
  download; GDAL adds its own working set). Don't set a low container limit.
  A 4-core / 8 GB VM builds the whole of a cycle in a few hours.

## First bring-up on a new host

1. Get the repo onto the host (git clone, or copy the tree — the image build
   needs `Server/` **and** `Packages/` plus the root `.dockerignore`,
   with the repo root as build context).
2. `cd Server && cp .env.example .env` and edit:
   - `FLIGHTBAG_BASE_URL` → `http://<HOST-LAN-IP>:8080`. This is baked into
     every product URL in `manifest.json`; if it's wrong, the app downloads
     from the wrong place. Changing it later requires re-running ingest
     (cheap — it only rebuilds the manifest once artifacts exist).
   - `FLIGHTBAG_ARTIFACTS_DIR` / `FLIGHTBAG_WORKDIR` → paths on the storage
     pool, and ideally outside the repo so a `git pull` never touches
     multi-GB artifacts. Both must be writable by the container's non-root user — if the
     first run fails with permission errors, `chown -R` the two host
     directories to the uid shown by
     `docker compose run --rm --entrypoint id server`.
   - Scope vars (`FLIGHTBAG_SECTIONALS`, `FLIGHTBAG_REGIONS`, IFR panels) —
     start small; see "Widening scope" below.
   - `FLIGHTBAG_NOTAM_CLIENT_ID` / `_SECRET` (optional) — FAA NOTAM
     Management Service credentials, requested by emailing NOTAMS@faa.gov.
     Leave them unset and everything else still works: the app shows
     "NOTAMs unavailable" rather than an empty list. See "NOTAMs" below.
3. Build and start:

   ```sh
   docker compose build          # first build compiles Swift: expect ~10-20 min
   docker compose up -d server
   curl http://<HOST-LAN-IP>:8080/v1/manifest   # empty manifest until ingest runs
   ```

4. First ingest (interactive, so you can watch it):

   ```sh
   docker compose --profile ingest run --rm ingest
   ```

   NASR + d-TPP + CIFP + worldwide OurAirports data (the airport/procedure
   database) always run; charts follow your scope. Expect ~40 MB of
   `aero.sqlite` and roughly 64 000 airports across 247 countries.

   The database carries a schema version (currently **5**). The app gates
   features on it and falls back gracefully on older ones, so a host still
   serving an earlier cycle will not break a newer app — but `kind`-based
   map/search filtering and worldwide coverage need 5 or later.
   A failure mid-run is fine — rerun and it resumes, skipping every artifact
   that already made it into the tree.

5. Point the app at the server: Settings → server URL →
   `http://<HOST-LAN-IP>:8080` (or launch arg `-serverBaseURL`). The
   Downloads tab's regions should populate from the manifest.

### NOTAMs

NOTAMs are the one app feature that *requires* this server. The FAA's NOTAM
Management Service (NMS, which replaced the US NOTAM System on 2026-04-18)
authenticates with OAuth 2.0 client credentials; those must not ship in an
app binary, so the token is fetched and refreshed here and the app reads
`/v1/airports/:id/notams`.

1. Email NOTAMS@faa.gov to request a client id and secret.
2. Put them in `.env` as `FLIGHTBAG_NOTAM_CLIENT_ID` /
   `FLIGHTBAG_NOTAM_CLIENT_SECRET`, then `docker compose up -d server`.
3. Check it:

   ```sh
   curl http://<HOST-LAN-IP>:8080/v1/airports/KAUS/notams
   ```

   `"configured": false` means the server did not see credentials — check the
   startup log, which says which way it resolved. Responses are cached per
   station for 15 minutes, so a repeated call should not hit the FAA again.

`FLIGHTBAG_NOTAM_ENV=fit` (or `staging`) points at the FAA's test
environments instead of production.

### Building the image elsewhere

A slow host CPU makes the Swift compile painful. Alternatives:

- Cross-build on a dev machine:
  `docker buildx build --platform linux/amd64 -f Server/Dockerfile -t flightbag-server .`
  then `docker save flightbag-server | ssh nas docker load`.
- Match the platform to the host (`linux/amd64` for Intel/AMD boxes,
  `linux/arm64` for ARM ones).

## Scheduling ingest

Run the trigger daily; it exits in seconds unless a new cycle's FAA data has
appeared (the FAA publishes ~20 days before each 28-day cycle's effective
date, and `ingest-all` HEAD-probes for it, so a daily cadence catches the
publication within a day):

```cron
PATH=/usr/local/bin:/usr/bin:/bin
14 3 * * *  /path/to/FlightBag/Server/scripts/ingest-cron.sh
```

Set `PATH` explicitly — cron's default is minimal and the script needs to find
`docker`. On Synology/QNAP use the built-in Task Scheduler with the same command.
Logs land in `Server/logs/ingest-YYYY-MM-DD.log`. Set
`FLIGHTBAG_FAIL_WEBHOOK` in `.env` (e.g. an https://ntfy.sh topic URL) to get
a push on failure.

What a scheduled run does, in order: pick target cycle (next if published,
else current; instant no-op via the cycle's `.complete` marker when done
already) → NASR + d-TPP + CIFP database → sectionals / IFR panels (both are
56-day editions and publish under the cycle they belong to, with `.expires`
sidecars)
→ basemap per `FLIGHTBAG_BASEMAP` policy → per-state plate bundles → rebuild
`manifest.json`. When the calendar rolls into a cycle that was pre-built, the
run also refreshes the manifest so next-cycle products graduate to current.

## Widening scope

Edit the scope vars in `.env`, **delete the target cycle's `.complete`
marker**, and rerun `docker compose --profile ingest run --rm ingest` —
skip-if-exists means only the newly added charts/regions build, then the
manifest refreshes.

The marker step is not optional and is easy to miss: `ingest-all` returns
immediately when `{artifacts}/{cycle}/.complete` exists and the manifest is
already current, so widening scope without removing it is a silent no-op that
prints "already complete and manifest current — nothing to do". Same applies
to rebuilding one artifact: delete its file *and* its `.sha256` sidecar *and*
the `.complete` marker, then rerun.

Artifacts are owned by the container's uid 999, so the host user usually
**cannot** delete them directly — go through a container:

```sh
docker compose --profile ingest run --rm --entrypoint sh ingest \
  -c "rm -f /app/Public/artifacts/<cycle>/.complete"
docker compose --profile ingest run --rm ingest
```

**The database is skipped independently of `.complete`.** A run logs
`db/aero.sqlite exists — skipping NASR/d-TPP` whenever the published database is
present, so any fix to database *content* — a d-TPP parsing change, say — has no
effect until the artifact itself is removed:

```sh
docker compose --profile ingest run --rm --entrypoint sh ingest -c "rm -f \
  /app/Public/artifacts/<cycle>/db/aero.sqlite \
  /app/Public/artifacts/<cycle>/db/aero.sqlite.sha256 \
  /app/Public/artifacts/<cycle>/.complete"
```

Deleting `.complete` alone is the classic mistake here: the run restarts, skips
the database, and cheerfully reports success having changed nothing.

Scope can also be overridden per-run without touching `.env` — shell
variables win over the `.env` file:

```sh
FLIGHTBAG_SECTIONALS=San_Antonio FLIGHTBAG_REGIONS=none FLIGHTBAG_BASEMAP=never \
  docker compose --profile ingest run --rm ingest
```

Forcing a specific cycle: append `--cycle 2607` to the run command.

## Later: TLS / domain

The stack is plain HTTP on the LAN by design. When a domain exists, add a
`caddy` service to docker-compose.yml reverse-proxying to `server:8080`
(Caddy auto-provisions certificates), stop publishing port 8080 directly,
and set `FLIGHTBAG_BASE_URL=https://data.example.com` + rerun ingest to
rebake manifest URLs. No image changes needed.

## Troubleshooting

- **Ingest died mid-run** — rerun it; downloads are cached in the workdir
  and finished artifacts are skipped. Nothing half-written is ever visible
  to the server (artifacts are staged in the workdir and moved into place).
- **"Only N GB free"** — the disk guard tripped; free space or lower
  `FLIGHTBAG_MIN_FREE_GB` deliberately.
- **App shows stale/empty regions** — check `curl <base-url>/v1/manifest`;
  if URLs point at the wrong host, fix `FLIGHTBAG_BASE_URL` and rerun ingest.
- **`gdalwarp ... No such file or directory`** — you're running `ingest-all`
  outside the container (the image is what provides GDAL), or the image
  build's apt step failed.
- **"No edition found"** — chart editions publish every other cycle;
  requesting one during an off cycle walks back automatically, so this usually
  means an FAA URL change. Check `aeronav.faa.gov/enroute/<MM-DD-YYYY>/` or
  `aeronav.faa.gov/visual/<MM-DD-YYYY>/sectional-files/`.
- **Run reports "N artifact(s) failed" and exits nonzero** — expected shape for
  a partial run, not a crash. Everything else published and the manifest is
  current; `.complete` was deliberately withheld. Just run it again, or let the
  next cron fire: it retries only the missing artifacts.
- **A change to the database seems to do nothing** — the run logs
  `db/aero.sqlite exists — skipping NASR/d-TPP`. Delete the database, its
  `.sha256` and `.complete`; see "Widening scope".
- **`rm: Permission denied` clearing artifacts** — they are owned by the
  container's uid 999. Delete through a container, see "Platform notes".
- **Ingest ran but nothing changed** — "already complete and manifest current".
  The `.complete` marker short-circuits the run; delete it first.
