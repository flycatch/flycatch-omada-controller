#!/usr/bin/env bash
# Filesystem-level backup of the Omada data volume (configuration + embedded MongoDB).
# Stops the controller for a consistent snapshot, writes a timestamped .tar.gz on the host,
# and restarts the controller if (and only if) this script stopped it.
#
# Usage: scripts/backup.sh [output-dir]      (default: ./backups)
# Env:   CONTAINER (omada-controller)  DATA_VOLUME (omada-data)  IMAGE (omada-controller:6.3.0.45)
#        STOP_TIMEOUT (120)
set -euo pipefail

CONTAINER="${CONTAINER:-omada-controller}"
DATA_VOLUME="${DATA_VOLUME:-omada-data}"
IMAGE="${IMAGE:-omada-controller:6.3.0.45}"
STOP_TIMEOUT="${STOP_TIMEOUT:-120}"
OUT_DIR="${1:-./backups}"

command -v docker >/dev/null || { echo "ERROR: docker not found" >&2; exit 1; }
docker volume inspect "$DATA_VOLUME" >/dev/null 2>&1 || { echo "ERROR: volume '$DATA_VOLUME' does not exist" >&2; exit 1; }

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FILE="omada-data-${STAMP}.tar.gz"

running() { [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" = "true" ]; }

WAS_RUNNING=0
if running; then
    WAS_RUNNING=1
    echo "Stopping $CONTAINER (timeout ${STOP_TIMEOUT}s) for a consistent backup..."
    docker stop -t "$STOP_TIMEOUT" "$CONTAINER" >/dev/null
fi
# Restart on any exit path if we stopped it.
restart() { [ "$WAS_RUNNING" = 1 ] && { echo "Restarting $CONTAINER..."; docker start "$CONTAINER" >/dev/null; WAS_RUNNING=0; }; }
trap restart EXIT

if running; then echo "ERROR: $CONTAINER is still running; refusing to back up" >&2; exit 1; fi

echo "Archiving volume '$DATA_VOLUME' -> $OUT_DIR/$FILE"
docker run --rm --platform linux/amd64 --entrypoint tar \
    -v "$DATA_VOLUME":/data:ro -v "$OUT_DIR":/backup \
    "$IMAGE" -czpf "/backup/$FILE" --numeric-owner -C /data .

[ -s "$OUT_DIR/$FILE" ] || { echo "ERROR: backup file is empty" >&2; exit 1; }
echo "Backup complete: $OUT_DIR/$FILE ($(du -h "$OUT_DIR/$FILE" | cut -f1))"
