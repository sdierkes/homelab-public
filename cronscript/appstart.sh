#!/bin/sh
# ---------------------------------------------------------------------------
# Host cron script for TrueNAS SCALE
# ---------------------------------------------------------------------------
# Purpose:
#   This script ensures a TrueNAS SCALE app is running before executing a
#   maintenance or update script inside its container. Optionally, it can stop
#   the app afterward if it was not originally running.
#
# Usage:
#   appstart.sh <APP_NAME> <CONTAINER> <RUN_SCRIPT> <LOGGER_TAG> [--stop-after]
#
# Parameters:
#   1. APP_NAME
#      - The name of the TrueNAS app as listed under "Apps" in the UI or by
#        running: midclt call app.query | jq '.[].name'
#      - Example: clamav
#
#   2. CONTAINER
#      - The exact name of the Docker container corresponding to that app.
#      - You can find it by running: docker ps
#      - Example: ix-clamav-clamav-1
#
#   3. RUN_SCRIPT
#      - The full path to the script or command you want to run *inside* the
#        container. This script should already exist inside the container.
#        IT'S NOT THE PATH IN TRUENAS!
#      - Example: /opt/host/usr/local/bin/clamav.sh
#
#   4. LOGGER_TAG
#      - A short identifier used for system logs (via `logger -t`).
#      - It helps identify messages in syslog (e.g. /var/log/syslog or via
#        journald) as coming from this cron task.
#      - Example: clamav-cron
#
#   5. --stop-after (optional)
#      - If provided, the script will stop the app again *after* running your
#        script inside it — but only if it wasn’t running before this script
#        started it.
#      - If omitted, the app stays running after the internal script finishes.
#
# Example:
#   appstart.sh clamav ix-clamav-clamav-1 /opt/host/usr/local/bin/clamav.sh clamav-cron --stop-after
#
# Typical cron entry example:
#   0 0 * * SUN /mnt/zpool/docker-mounts/cron-scripts/appstart.sh clamav ix-clamav-clamav-1 /opt/host/usr/local/bin/clamav.sh clamav-cron --stop-after
#
# ---------------------------------------------------------------------------

# --- Validate input ---
if [ $# -lt 4 ]; then
    echo "Usage: $0 <APP_NAME> <CONTAINER> <RUN_SCRIPT> <LOGGER_TAG> [--stop-after]" >&2
    exit 1
fi

# --- Parameters ---
APP_NAME="$1"       # TrueNAS app name
CONTAINER="$2"      # Docker container name
RUN_SCRIPT="$3"     # Script to run inside container
LOGGER_TAG="$4"     # Tag used in syslog messages
MAX_WAIT=30         # Maximum seconds to wait for app to reach RUNNING state

STOP_AFTER=0
[ "$5" = "--stop-after" ] && STOP_AFTER=1

# --- Logging helper function ---
log() {
    logger -t "$LOGGER_TAG" "$*"
}

# --- Get current state of app from TrueNAS API ---
get_state() {
    midclt call app.get_instance "$APP_NAME" 2>/dev/null \
        | python3 -c 'import sys, json; print(json.load(sys.stdin)["state"])'
}

# --- 1) Check current state of the app ---
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

# --- 2) Wait until app is RUNNING (poll every second) ---
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

# --- 3) Execute user-specified script inside container ---
log "Running script $RUN_SCRIPT in container '$CONTAINER'..."
if ! docker exec "$CONTAINER" "$RUN_SCRIPT" >/dev/null 2>&1; then
    log "ERROR: $RUN_SCRIPT script failed inside container."
    if [ "$WAS_RUNNING" -eq 0 ] && [ "$STOP_AFTER" -eq 1 ]; then
        midclt call app.stop "$APP_NAME" >/dev/null 2>&1
    fi
    exit 1
fi
log "$RUN_SCRIPT script finished successfully."

# --- 4) Optionally stop app again if it was started by this script ---
if [ "$STOP_AFTER" -eq 1 ] && [ "$WAS_RUNNING" -eq 0 ]; then
    log "Stopping app '$APP_NAME' again (we started it)..."
    midclt call app.stop "$APP_NAME" >/dev/null 2>&1
fi

exit 0
