#!/bin/bash
# Starts the Omada controller through the package's own bin/control.sh (jsvc daemon; the
# controller launches its embedded mongod), stays in the foreground, and stops it gracefully on SIGTERM.
OMADA_HOME=/opt/tplink/EAPController
export OMADA_USER=omada
MAIN_CLASS=com.tplink.smb.omada.starter.OmadaLinuxMain
CTL="${OMADA_HOME}/bin/control.sh"

log() { echo "[entrypoint] $*"; }

TAIL_PID=""
START_PID=""
stopping=0

shutdown() {
    stopping=1
    log "signal received, stopping Omada Network Application"
    [ -n "$START_PID" ] && kill "$START_PID" 2>/dev/null
    "$CTL" stop
    [ -n "$TAIL_PID" ] && kill "$TAIL_PID" 2>/dev/null
    exit 0
}
trap shutdown TERM INT

# Seed data dir from the image skeleton (needed when a bind mount / fresh volume is empty).
mkdir -p "${OMADA_HOME}/data" "${OMADA_HOME}/logs" "${OMADA_HOME}/work"
cp -a --update=none /opt/omada-data-skel/. "${OMADA_HOME}/data/"
mkdir -p "${OMADA_HOME}/data/autobackup" "${OMADA_HOME}/data/check-mongo"

# control.sh prompts interactively if the Mongo major version jumps; record the installed one
# on first start so it never blocks. (A real jump on an existing data dir still prompts - and
# fails fast with no TTY - which is intended: see README upgrade notes.)
VERFILE="${OMADA_HOME}/data/check-mongo/LAST_MAIN_VERSION.info"
if [ ! -s "$VERFILE" ] && [ ! -e "${OMADA_HOME}/data/db/WiredTiger" ]; then
    "${OMADA_HOME}/bin/mongod" --version 2>/dev/null | grep -oP 'db version v\K[0-9]+\.[0-9]+\.[0-9]+' > "$VERFILE"
fi

# Pre-create log files (before chown, so they end up owned by omada).
touch "${OMADA_HOME}/logs/startup.log" "${OMADA_HOME}/logs/server.log" "${OMADA_HOME}/logs/mongod.log"
for d in data logs work; do
    find "${OMADA_HOME}/${d}" ! -user "$OMADA_USER" -exec chown "$OMADA_USER:$OMADA_USER" {} + 2>/dev/null
done
rm -f /var/run/omada.pid

# Surface logs through `docker logs`.
tail -n +1 -F "${OMADA_HOME}/logs/startup.log" "${OMADA_HOME}/logs/server.log" "${OMADA_HOME}/logs/mongod.log" &
TAIL_PID=$!

log "starting controller via control.sh"
"$CTL" start </dev/null &
START_PID=$!

while [ "$stopping" = 0 ]; do
    sleep 5 &
    wait $!
    # Once control.sh start has returned, the jsvc daemon must stay up.
    if ! kill -0 "$START_PID" 2>/dev/null; then
        if ! pgrep -f "$MAIN_CLASS" >/dev/null; then
            log "controller process is not running; exiting"
            kill "$TAIL_PID" 2>/dev/null
            exit 1
        fi
    fi
done
