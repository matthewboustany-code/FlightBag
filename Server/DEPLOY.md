# Deploying the FlightBag data server

The data server is one Docker image with two roles: the Vapor API +
artifact hosting (`serve`, the default), and the per-AIRAC-cycle chart
production pipeline (`ingest-all`). Everything is orchestrated by
[docker-compose.yml](docker-compose.yml) and configured through a `.env`
file — see [.env.example](.env.example).

Status: the stack was authored and macOS-verified (through 2026-07, including
a full `ingest-all` run producing a schema-5 database plus open flightmaps
charts). As of 2026-07-30 the image **also builds and serves on Docker**
(Docker 29.6.2 / compose v5.3.1 on an arm64 Mac): `docker compose build server`
compiles `App` clean with no errors, `docker compose up -d server` reaches the
`healthy` healthcheck, and `/v1/manifest` returns the 2607 manifest. GDAL 3.8.4
and `unzip`/`zip`/`curl` are all present on `PATH` in the runtime image.

The **chart pipeline has now run too**: an `ingest-all` scoped to the single
San_Antonio sectional completed clean, exercising the full
`gdal_translate -expand rgba` → `gdalwarp` → MBTiles → `gdaladdo` chain for the
first time. It produced a 254 MB / 7 222-tile MBTiles (zoom 6–12, EPSG:3857)
with a matching `.sha256`, and the server serves it with range requests
(`206 Partial Content`), which the app's download resume depends on.

**The band-count question in item 2 below is settled: it reports 4.**
`gdalwarp -dstalpha` treats the `-expand rgba` alpha as source alpha rather
than adding a fifth band, so the MBTILES driver is happy and `-dstalpha`
should stay.

**NASR/d-TPP/CIFP ingestion is now proven on Linux too.** On 2026-08-05 a
database-only run on the Debian/Proxmox Docker VM (`debian4docker`, amd64) built
a schema-5 `aero.sqlite` from scratch: 64 007 airports, 9 129 navaids, 24 090
plates, 4 010 CIFP procedures / 73 314 legs, published with a matching `.sha256`
and served with range requests (`206`).

That run surfaced one genuine Linux-only defect, now fixed in
`DTPPIngestor.swift` — see "The d-TPP 10 MB parser limit" below.

Still unproven: d-TPP plate *bundling* (the per-state PDF bundles; the metafile
parse itself is proven), the basemap build, and IFR enroute panels.

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
never closes its root, so that stays a real failure. Plate count matches the
metafile's record count exactly (24 090), confirming nothing is dropped.

**If another ingestor ever parses XML over 10 MB on Linux, it will hit this
same wall** — apply the same pattern rather than assuming a bad download.

Note also that the Swift build does long `git` fetches during
`swift package resolve` (vapor alone took ~8 min on a slow link); if the Docker
VM restarts mid-build the CLI can hang indefinitely on an orphaned buildkit
session — kill it and rerun, the fetch cache survives.

What a wider ingest run is most likely to catch, in rough order:

1. **Linux Foundation gaps.** Every file under `Sources/App/Ingest/` carries
   the `#if canImport(FoundationNetworking)` guard, and all downloads go
   through `URLSession.data(for:)` rather than the async `download(from:)`
   family, whose swift-corelibs coverage is thinner. Both are deliberate; keep
   new ingestors to the same pattern. The chart download path is proven on
   Linux (the San_Antonio zip pulled fine); NASR/d-TPP/CIFP downloads are not
   yet — those are the larger, longer transfers where corelibs is likelier to
   differ from Darwin.
2. **GDAL.** The tile pipeline shells out to
   `gdal_translate`/`gdalwarp`/`gdaladdo`, all present in the image as GDAL
   3.8.4, and the sectional chain is now proven end to end. `ingest-all`
   preflights the tools and logs the version before downloading anything, and
   skips that check when no charts are in scope. Still bring the database up
   first and add one sectional second when widening scope, so a chart failure
   costs one download rather than fifty.

   Band count is settled for sectionals: the pipeline yields **4** (RGBA), so
   `gdalwarp -dstalpha` is correctly treating the `-expand rgba` alpha as
   source alpha rather than adding a fifth band, which the MBTILES driver
   would refuse. Re-check it on the first IFR enroute panel, whose source
   rasters differ:

   ```sh
   gdalinfo <artifacts>/<cycle>/tiles/<chart>.mbtiles | grep -c '^Band '
   ```

   4 is correct. If it reports 5, drop `-dstalpha` from the `gdalwarp` call in
   `TilePipeline.buildChart` — the alpha from `-expand rgba` is already there.
   (The `mercator.tif` intermediate is cleaned up on success, so inspect the
   finished MBTiles rather than the workdir.)
3. **Volume permissions.** The container runs as a non-root `vapor` user; see
   the `chown` note in step 2 below.

## Prerequisites

- Docker with the compose plugin (Container Manager on Synology, Apps on
  TrueNAS SCALE, etc. all provide it).
- Disk: budget ~2–4 GB per sectional/panel MBTiles plus similar transient
  workdir space, ~0.3–3 GB per state plate bundle, ~1 GB basemap.
  "Everything" (53 sectionals + 48 IFR panels + 51 plate regions) is
  roughly 100+ GB per cycle, and two cycles coexist during rollover —
  scope accordingly via `.env`.
- Memory: allow ~2 GB for ingest (chart zips are held in memory during
  download; GDAL adds its own working set). Don't set a low container limit.

## First bring-up on the NAS

1. Get the repo onto the NAS (git clone, or copy the tree — the image build
   needs `Server/` **and** `Packages/` plus the root `.dockerignore`,
   with the repo root as build context).
2. `cd Server && cp .env.example .env` and edit:
   - `FLIGHTBAG_BASE_URL` → `http://<NAS-LAN-IP>:8080`. This is baked into
     every product URL in `manifest.json`; if it's wrong, the app downloads
     from the wrong place. Changing it later requires re-running ingest
     (cheap — it only rebuilds the manifest once artifacts exist).
   - `FLIGHTBAG_ARTIFACTS_DIR` / `FLIGHTBAG_WORKDIR` → paths on the storage
     pool. Both must be writable by the container's non-root user — if the
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
   curl http://<NAS-LAN-IP>:8080/v1/manifest   # empty manifest until ingest runs
   ```

4. First ingest (interactive, so you can watch it):

   ```sh
   docker compose --profile ingest run --rm ingest
   ```

   NASR + d-TPP + CIFP + worldwide OurAirports data (the airport/procedure
   database) always run; charts follow your scope. Expect ~40 MB of
   `aero.sqlite` and roughly 64 000 airports across 247 countries.

   The database carries a schema version (currently **5**). The app gates
   features on it and falls back gracefully on older ones, so a NAS still
   serving an earlier cycle will not break a newer app — but `kind`-based
   map/search filtering and worldwide coverage need 5 or later.
   A failure mid-run is fine — rerun and it resumes, skipping every artifact
   that already made it into the tree.

5. Point the app at the server: Settings → server URL →
   `http://<NAS-LAN-IP>:8080` (or launch arg `-serverBaseURL`). The
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
   curl http://<NAS-LAN-IP>:8080/v1/airports/KAUS/notams
   ```

   `"configured": false` means the server did not see credentials — check the
   startup log, which says which way it resolved. Responses are cached per
   station for 15 minutes, so a repeated call should not hit the FAA again.

`FLIGHTBAG_NOTAM_ENV=fit` (or `staging`) points at the FAA's test
environments instead of production.

### Building the image elsewhere

The NAS CPU may be slow for the Swift compile. Alternatives:

- Cross-build on a dev machine:
  `docker buildx build --platform linux/amd64 -f Server/Dockerfile -t flightbag-server .`
  then `docker save flightbag-server | ssh nas docker load`.
- Match the platform to the NAS (`linux/amd64` for Intel/AMD boxes,
  `linux/arm64` for ARM ones).

## Scheduling ingest

Run the trigger daily; it exits in seconds unless a new cycle's FAA data has
appeared (the FAA publishes ~20 days before each 28-day cycle's effective
date, and `ingest-all` HEAD-probes for it, so a daily cadence catches the
publication within a day):

```cron
14 3 * * *  /path/on/nas/FlightBag/Server/scripts/ingest-cron.sh
```

On Synology/QNAP use the built-in Task Scheduler with the same command.
Logs land in `Server/logs/ingest-YYYY-MM-DD.log`. Set
`FLIGHTBAG_FAIL_WEBHOOK` in `.env` (e.g. an https://ntfy.sh topic URL) to get
a push on failure.

What a scheduled run does, in order: pick target cycle (next if published,
else current; instant no-op via the cycle's `.complete` marker when done
already) → NASR + d-TPP + CIFP database → sectionals / IFR panels (IFR editions are
56-day and publish under the cycle they belong to, with `.expires` sidecars)
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

```sh
rm Public/artifacts/<cycle>/.complete
docker compose --profile ingest run --rm ingest
```

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
- **Enroute panel "No ... edition found"** — IFR editions publish every
  other cycle; requesting one during an off cycle walks back automatically,
  so this usually means an FAA URL change. Check
  `aeronav.faa.gov/enroute/<MM-DD-YYYY>/`.
