# Deploying the FlightBag data server

The data server is one Docker image with two roles: the Vapor API +
artifact hosting (`serve`, the default), and the per-AIRAC-cycle chart
production pipeline (`ingest-all`). Everything is orchestrated by
[docker-compose.yml](docker-compose.yml) and configured through a `.env`
file — see [.env.example](.env.example).

Status: the stack was authored and macOS-verified 2026-07 but **has not yet
had a real Docker build or GDAL run** (no container runtime on the dev Mac).
Expect the first `docker compose build` on the NAS to be the shakedown for
the Linux build; `Sources/App/Ingest/*` already carries the
`FoundationNetworking` guards Linux needs.

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

   NASR + d-TPP + CIFP (the airport/procedure database) always run; charts follow your scope.
   A failure mid-run is fine — rerun and it resumes, skipping every artifact
   that already made it into the tree.

5. Point the app at the server: Settings → server URL →
   `http://<NAS-LAN-IP>:8080` (or launch arg `-serverBaseURL`). The
   Downloads tab's regions should populate from the manifest.

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

Edit the scope vars in `.env` and rerun
`docker compose --profile ingest run --rm ingest` — skip-if-exists means only
the newly added charts/regions build, then the manifest refreshes. Forcing a
specific cycle: append `--cycle 2607` to the run command. Rebuilding one
artifact: delete its file (and `.sha256` sidecar) from the artifact tree and
rerun.

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
