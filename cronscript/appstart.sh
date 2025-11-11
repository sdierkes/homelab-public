#!/bin/sh
# Host cron script for TrueNAS SCALE
# - ensures the app is running (via midclt app.start)
# - waits until it is RUNNING
# - runs the script inside the container
# - optionally stops the app again if we started it
#
# usage:
#   appstart.sh
#   appstart.sh --stop-after

APP_NAME="INSERT APP_NAME HERE"   # e.g. "clamav"
CONTAINER="INSERT CONTAINER NAME HERE" # e.g. "ix-clamav-clamav-1" (from your `docker ps`)
RUN_SCRIPT="INSERT SCRIPT HEREE" # e.g. "/opt/host/usr/local/bin/clamav.sh"
LOGGER_TAG="INSERT TAG FOR SYSLOG"  # e.g. "clamav-cron"
MAX_WAIT=30

STOP_AFTER=0
[ "$1" = "--stop-after" ] && STOP_AFTER=1

log() {
    logger -t "$LOGGER_TAG" "$*"
}

get_state() {
    # read JSON and print only the top-level app state
    midclt call app.get_instance "$APP_NAME" 2>/dev/null \
        | python3 -c 'import sys, json; print(json.load(sys.stdin)["state"])'
}

# --- 1) check current state ---
CURRENT_STATE=$(get_state)

if [ -z "$CURRENT_STATE" ]; then
    log "ERROR: app '$APP_NAME' not found via midclt."
    exit 1
fi

WAS_RUNNING=1
if [ "$CURRENT_STATE" != "RUNNING" ]; then
    WAS_RUNNING=0
    log "App '$APP_NAME' is $CURRENT_STATE, starting..."
    if ! midclt call app.start "$APP_NAME" >/dev/null 2>&1; then
        log "ERROR: failed to start app '$APP_NAME' via midclt."
        exit 1
    fi
fi

# --- 2) wait until RUNNING ---
i=0
STATE="$CURRENT_STATE"
while [ "$i" -lt "$MAX_WAIT" ]; do
    STATE=$(get_state)
    [ "$STATE" = "RUNNING" ] && break
    sleep 1
    i=$((i+1))
done

if [ "$STATE" != "RUNNING" ]; then
    log "ERROR: app '$APP_NAME' did not become RUNNING (last state: $STATE)."
    if [ "$WAS_RUNNING" -eq 0 ] && [ "$STOP_AFTER" -eq 1 ]; then
        midclt call app.stop "$APP_NAME" >/dev/null 2>&1
    fi
    exit 1
fi

# --- 3) run the script inside the container ---
# You might want to change this depending on your needs
log "Running script $RUN_SCRIPT in container '$CONTAINER'..."
if ! docker exec "$CONTAINER" "$RUN_SCRIPT" >/dev/null 2>&1; then
    log "ERROR: $RUN_SCRIPT script failed inside container."
    if [ "$WAS_RUNNING" -eq 0 ] && [ "$STOP_AFTER" -eq 1 ]; then
        midclt call app.stop "$APP_NAME" >/dev/null 2>&1
    fi
    exit 1
fi
log "$RUN_SCRIPT script finished successfully."

# --- 4) stop again if we started it and user asked ---
if [ "$STOP_AFTER" -eq 1 ] && [ "$WAS_RUNNING" -eq 0 ]; then
    log "Stopping app '$APP_NAME' again (we started it)..."
    midclt call app.stop "$APP_NAME" >/dev/null 2>&1
fi

exit 0
