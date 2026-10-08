#!/usr/bin/env bash
# Restore the Omada data volume from an archive produced by scripts/backup.sh.
# REPLACES the contents of the data volume. The controller container MUST be stopped.
#
# Usage: scripts/restore.sh <backup.tar.gz>
# Env:   CONTAINER (omada-controller)  DATA_VOLUME (omada-data)  IMAGE (omada-controller:6.3.0.45)
set -euo pipefail

CONTAINER="${CONTAINER:-omada-controller}"
DATA_VOLUME="${DATA_VOLUME:-omada-data}"
IMAGE="${IMAGE:-omada-controller:6.3.0.45}"

[ $# -eq 1 ] || { echo "Usage: $0 <backup.tar.gz>" >&2; exit 2; }
ARCHIVE="$1"
[ -s "$ARCHIVE" ] || { echo "ERROR: backup file '$ARCHIVE' not found or empty" >&2; exit 1; }
command -v docker >/dev/null || { echo "ERROR: docker not found" >&2; exit 1; }

# Refuse unless we can positively confirm the container is not running.
if ! state="$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)"; then
    # inspect failed: container absent (fine) vs. docker unreachable (not fine)
    docker info >/dev/null 2>&1 || { echo "ERROR: cannot reach Docker; cannot confirm '$CONTAINER' is stopped" >&2; exit 1; }
    state=false
fi
if [ "$state" != "false" ]; then
    echo "ERROR: container '$CONTAINER' is running. Stop it first (docker compose stop) and retry." >&2
    exit 1
fi

ARCHIVE_ABS="$(cd "$(dirname "$ARCHIVE")" && pwd)/$(basename "$ARCHIVE")"
# Validate the archive before touching the volume.
docker run --rm --platform linux/amd64 --entrypoint tar -v "$ARCHIVE_ABS":/backup/in.tar.gz:ro "$IMAGE" -tzf /backup/in.tar.gz >/dev/null \
    || { echo "ERROR: '$ARCHIVE' is not a valid tar.gz archive; volume left untouched" >&2; exit 1; }

docker volume inspect "$DATA_VOLUME" >/dev/null 2>&1 || docker volume create "$DATA_VOLUME" >/dev/null

echo "Restoring '$ARCHIVE' into volume '$DATA_VOLUME' (existing contents will be replaced)..."
docker run --rm --platform linux/amd64 --entrypoint bash \
    -v "$DATA_VOLUME":/data -v "$ARCHIVE_ABS":/backup/in.tar.gz:ro \
    "$IMAGE" -c 'set -e; find /data -mindepth 1 -delete; tar -xzpf /backup/in.tar.gz --numeric-owner -C /data'

echo "Restore complete. Start the controller with: docker compose up -d"
