#!/usr/bin/env bash
# Rebuilds /opt/platform/stations/stations.json from NaPTAN (served at
# https://api.whatplatform.uk/stations.json). Monthly from ubuntu's crontab:
#   17 4 3 * * /usr/bin/bash /opt/platform/repo/deploy/stations/refresh.sh >> /opt/platform/stations/refresh.log 2>&1
# build_stations.py validates the list and replaces the file atomically: on any failure the
# previous file stays. A lock keeps a manual run and cron from overlapping.
set -euo pipefail
REPO=${REPO:-/opt/platform/repo}
OUT_DIR=${OUT_DIR:-/opt/platform/stations}
export PYTHONDONTWRITEBYTECODE=1

log() { echo "$(date -u +%FT%TZ) $*"; }
trap 'log "failed (line $LINENO)"' ERR

exec 9>"$OUT_DIR/.refresh.lock"
if ! flock -n 9; then
  log "another refresh is running"
  exit 0
fi
log "start"
python3 "$REPO/pipeline/build_stations.py" --out "$OUT_DIR/stations.json"
log "done"
