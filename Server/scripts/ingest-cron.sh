#!/usr/bin/env bash
# Daily ingest trigger for cron / the NAS task scheduler:
#   14 3 * * *  /path/to/FlightBag/Server/scripts/ingest-cron.sh
# Cheap no-op unless a new AIRAC cycle's FAA data has been published
# (ingest-all exits immediately on its .complete marker otherwise).
set -uo pipefail
cd "$(dirname "$0")/.."

# cron starts with an empty environment; pull in the compose .env so
# FLIGHTBAG_FAIL_WEBHOOK (and anything else) is visible here too.
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

mkdir -p logs
log="logs/ingest-$(date +%F).log"
{
  echo "=== ingest run $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="
  docker compose --profile ingest run --rm ingest
} >>"$log" 2>&1
status=$?

if [[ $status -ne 0 && -n "${FLIGHTBAG_FAIL_WEBHOOK:-}" ]]; then
  curl -fsS -m 10 -X POST --data "FlightBag ingest failed (exit $status); see $log on the server" \
    "$FLIGHTBAG_FAIL_WEBHOOK" || true
fi
exit "$status"
