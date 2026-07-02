#!/bin/bash
# =============================================================================
# usb-backup.sh — Automated USB Backup for TrueNAS Scale
# =============================================================================
# Runs via cron every 10 minutes.
# Detects USB drive by serial number, imports ZPool backup-usb,
# starts the configured replication task, exports the pool afterward.
# Enforces a minimum 24h interval between runs.
#
# Hardened version:
# - waits until the ZFS pool is actually visible/importable after USB detection
# - refuses to replicate if the target pool is not healthy
# - disables the replication task on failures after it was enabled
# - verifies replication job lookup and state handling
# - verifies the pool again before export and after export
# =============================================================================

set -u

# --- Configuration ---
USB_SERIAL="CHANGE_ME_USB_SERIAL"   # Required: USB drive serial number (lsblk -o NAME,SERIAL,TRAN)
ZPOOL_NAME="backup-usb"           # Name of the USB ZPool
ZPOOL_ALTROOT="/mnt"              # TrueNAS mounts ZPools under /mnt
REPLICATION_ID=0                     # Required: TrueNAS Replication Task ID
LOCKFILE="/var/run/usb-backup.lock"        # Prevents parallel execution
LASTRUN_FILE="/var/db/usb-backup.lastrun"  # Timestamp of last successful run
MIN_INTERVAL=$((24 * 3600))       # 24h in seconds
LOGFILE="/var/log/usb-backup.log"

# Wait/retry behavior
POOL_IMPORT_WAIT_SECONDS=180      # wait up to 3 minutes for ZFS to see the USB pool
POOL_IMPORT_SLEEP_SECONDS=10
JOB_MAX_WAIT=$((24 * 3600))       # maximum wait time for replication job: 24h
JOB_POLL_INTERVAL=30
EXPORT_WAIT_SECONDS=60            # wait up to 60s for pool to disappear after export
EXPORT_POLL_INTERVAL=5

# --- Runtime state ---
LOCK_CREATED=0
TASK_ENABLED_BY_SCRIPT=0
POOL_IMPORTED_BY_SCRIPT=0

# --- Logging ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOGFILE"
}

cleanup() {
    RC=$?

    if [ "$TASK_ENABLED_BY_SCRIPT" -eq 1 ]; then
        log "INFO: Cleanup: disabling Replication Task ID $REPLICATION_ID."
        midclt call replication.update "$REPLICATION_ID" '{"enabled": false}' >> "$LOGFILE" 2>&1 || \
            log "WARN: Cleanup: failed to disable Replication Task ID $REPLICATION_ID."
    fi

    if [ "$LOCK_CREATED" -eq 1 ]; then
        rm -f "$LOCKFILE"
        log "INFO: Lock file removed."
    fi

    exit "$RC"
}
trap cleanup EXIT

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        log "ERROR: Required command not found: $1"
        exit 1
    fi
}

pool_is_imported() {
    zpool list -H -o name "$ZPOOL_NAME" >/dev/null 2>&1
}

pool_is_importable() {
    zpool import 2>/dev/null | grep -q "pool: $ZPOOL_NAME"
}

log_pool_status() {
    log "INFO: Current ZPool status for '$ZPOOL_NAME':"
    zpool status -v "$ZPOOL_NAME" >> "$LOGFILE" 2>&1 || true
}

assert_pool_healthy() {
    local CONTEXT="$1"
    local STATUS

    if ! pool_is_imported; then
        log "ERROR: $CONTEXT: ZPool '$ZPOOL_NAME' is not imported."
        exit 1
    fi

    STATUS=$(zpool status -x "$ZPOOL_NAME" 2>&1 || true)

    if echo "$STATUS" | grep -q "pool '$ZPOOL_NAME' is healthy"; then
        log "INFO: $CONTEXT: ZPool '$ZPOOL_NAME' is healthy."
        return 0
    fi

    log "ERROR: $CONTEXT: ZPool '$ZPOOL_NAME' is NOT healthy — replication will not run."
    echo "$STATUS" >> "$LOGFILE"
    log_pool_status
    exit 1
}

wait_until_pool_visible() {
    local WAITED=0

    while [ "$WAITED" -le "$POOL_IMPORT_WAIT_SECONDS" ]; do
        if pool_is_imported; then
            log "INFO: ZPool '$ZPOOL_NAME' is already imported."
            return 0
        fi

        if pool_is_importable; then
            log "INFO: ZPool '$ZPOOL_NAME' is visible as importable."
            return 0
        fi

        log "INFO: USB drive is visible, but ZPool '$ZPOOL_NAME' is not importable yet — waiting ${POOL_IMPORT_SLEEP_SECONDS}s..."
        sleep "$POOL_IMPORT_SLEEP_SECONDS"
        WAITED=$((WAITED + POOL_IMPORT_SLEEP_SECONDS))
    done

    log "ERROR: USB drive is visible, but ZPool '$ZPOOL_NAME' did not become importable within ${POOL_IMPORT_WAIT_SECONDS}s."
    zpool import >> "$LOGFILE" 2>&1 || true
    exit 1
}

export_pool_if_needed() {
    if ! pool_is_imported; then
        log "INFO: ZPool '$ZPOOL_NAME' is already exported/not imported."
        return 0
    fi

    log "INFO: Exporting ZPool '$ZPOOL_NAME'..."
    sync

    if ! zpool export "$ZPOOL_NAME" >> "$LOGFILE" 2>&1; then
        log "WARN: ZPool export failed — pool may still be in use."
        log_pool_status
        return 1
    fi

    local WAITED=0
    while [ "$WAITED" -le "$EXPORT_WAIT_SECONDS" ]; do
        if ! pool_is_imported; then
            log "INFO: ZPool '$ZPOOL_NAME' successfully exported. Drive can be powered off."
            return 0
        fi
        sleep "$EXPORT_POLL_INTERVAL"
        WAITED=$((WAITED + EXPORT_POLL_INTERVAL))
    done

    log "WARN: ZPool '$ZPOOL_NAME' export command returned success, but pool still appears imported."
    log_pool_status
    return 1
}

# --- Precondition checks ---
require_command midclt
require_command zpool
require_command zfs
require_command lsblk
require_command awk
require_command python3

# --- Replication task exists check ---
TASK_EXISTS=$(midclt call replication.query 2>/dev/null | python3 -c "
import sys, json
try:
    tasks = json.load(sys.stdin)
    match = [t for t in tasks if t.get('id') == $REPLICATION_ID]
    print('yes' if match else 'no')
except Exception:
    print('no')
")
if [ "$TASK_EXISTS" != "yes" ]; then
    log "ERROR: Replication Task ID $REPLICATION_ID not found. Check REPLICATION_ID in script."
    exit 1
fi

# --- Lock file check (prevent parallel runs) ---
if [ -e "$LOCKFILE" ]; then
    PID=$(cat "$LOCKFILE" 2>/dev/null || true)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        log "INFO: Script already running (PID $PID), exiting."
        exit 0
    else
        log "WARN: Stale lock file found, removing."
        rm -f "$LOCKFILE"
    fi
fi

# --- 24h interval check ---
if [ -f "$LASTRUN_FILE" ]; then
    LAST=$(cat "$LASTRUN_FILE" 2>/dev/null || echo 0)
    NOW=$(date +%s)

    if ! echo "$LAST" | grep -Eq '^[0-9]+$'; then
        log "WARN: Invalid last-run timestamp in $LASTRUN_FILE — ignoring it."
    else
        DIFF=$(( NOW - LAST ))
        if [ "$DIFF" -lt "$MIN_INTERVAL" ]; then
            REMAINING=$(( MIN_INTERVAL - DIFF ))
            log "INFO: Last run was $(( DIFF / 3600 ))h $(( (DIFF % 3600) / 60 ))m ago – next run in $(( REMAINING / 3600 ))h $(( (REMAINING % 3600) / 60 ))m."
            exit 0
        fi
    fi
fi

# --- Check if USB drive is present ---
USB_DEV=$(lsblk -o NAME,SERIAL -d 2>/dev/null | awk -v serial="$USB_SERIAL" '$2 == serial {print $1; exit}')
if [ -z "$USB_DEV" ]; then
    log "INFO: USB drive (Serial: $USB_SERIAL) not found – skipping."
    exit 0
fi
log "INFO: USB drive found: /dev/$USB_DEV (Serial: $USB_SERIAL)"

# --- Set lock file only after drive was found and the 24h lock passed ---
echo $$ > "$LOCKFILE"
LOCK_CREATED=1

# --- Wait until the ZFS pool is visible/importable ---
wait_until_pool_visible

# --- Import ZPool if not already imported ---
if pool_is_imported; then
    log "INFO: ZPool '$ZPOOL_NAME' is already imported."
    POOL_IMPORTED_BY_SCRIPT=0
else
    log "INFO: Importing ZPool '$ZPOOL_NAME' (altroot: $ZPOOL_ALTROOT)..."
    if ! zpool import -R "$ZPOOL_ALTROOT" "$ZPOOL_NAME" >> "$LOGFILE" 2>&1; then
        log "ERROR: ZPool import failed – aborting."
        exit 1
    fi
    POOL_IMPORTED_BY_SCRIPT=1
    log "INFO: ZPool '$ZPOOL_NAME' successfully imported."
fi

# --- Hard stop if target pool is not healthy ---
assert_pool_healthy "Pre-replication health check"

# --- Enable replication task ---
log "INFO: Enabling Replication Task ID $REPLICATION_ID..."
if ! midclt call replication.update "$REPLICATION_ID" '{"enabled": true}' >> "$LOGFILE" 2>&1; then
    log "ERROR: Failed to enable replication task."
    export_pool_if_needed || true
    exit 1
fi
TASK_ENABLED_BY_SCRIPT=1

# --- Start replication task ---
log "INFO: Starting Replication Task ID $REPLICATION_ID..."
JOB_ID=$(midclt call replication.run "$REPLICATION_ID" 2>&1)
if [ $? -ne 0 ]; then
    log "ERROR: Failed to start replication task: $JOB_ID"
    export_pool_if_needed || true
    exit 1
fi

if ! echo "$JOB_ID" | grep -Eq '^[0-9]+$'; then
    log "ERROR: Replication run returned an unexpected Job-ID: $JOB_ID"
    export_pool_if_needed || true
    exit 1
fi
log "INFO: Replication job started, Job-ID: $JOB_ID"

# --- Disable replication task immediately after start ---
log "INFO: Disabling Replication Task ID $REPLICATION_ID again..."
if midclt call replication.update "$REPLICATION_ID" '{"enabled": false}' >> "$LOGFILE" 2>&1; then
    TASK_ENABLED_BY_SCRIPT=0
else
    log "WARN: Failed to disable replication task after job start. Cleanup will retry if needed."
fi

# --- Wait for job completion ---
log "INFO: Waiting for replication job to complete (ID: $JOB_ID)..."
ELAPSED=0

while true; do
    STATUS=$(midclt call core.get_jobs 2>/dev/null | python3 -c "
import sys, json
try:
    jobs = json.load(sys.stdin)
    for j in jobs:
        if j.get('id') == $JOB_ID:
            print(j.get('state', 'UNKNOWN'))
            break
    else:
        print('NOT_FOUND')
except Exception:
    print('UNKNOWN')
" 2>/dev/null)

    case "$STATUS" in
        SUCCESS)
            log "INFO: Replication job completed successfully."
            break
            ;;
        FAILED|ABORTED)
            log "ERROR: Replication job failed (state: $STATUS)."
            midclt call core.get_jobs 2>/dev/null | python3 -c "
import sys, json
try:
    jobs = json.load(sys.stdin)
    for j in jobs:
        if j.get('id') == $JOB_ID:
            print(j)
            break
except Exception as e:
    print(e)
" >> "$LOGFILE" 2>&1 || true
            export_pool_if_needed || true
            exit 1
            ;;
        RUNNING|WAITING)
            log "INFO: Job still running (state: $STATUS, elapsed: ${ELAPSED}s)..."
            ;;
        NOT_FOUND)
            log "WARN: Replication job ID $JOB_ID not found in core.get_jobs — retrying..."
            ;;
        *)
            log "WARN: Unknown state: '$STATUS' – retrying..."
            ;;
    esac

    if [ "$ELAPSED" -ge "$JOB_MAX_WAIT" ]; then
        log "ERROR: Timeout after ${JOB_MAX_WAIT}s – aborting."
        export_pool_if_needed || true
        exit 1
    fi

    sleep "$JOB_POLL_INTERVAL"
    ELAPSED=$(( ELAPSED + JOB_POLL_INTERVAL ))
done

# --- Verify pool health after replication and before export ---
assert_pool_healthy "Post-replication health check"

# --- Export ZPool ---
if ! export_pool_if_needed; then
    log "ERROR: Pool export could not be verified. Do NOT power off the USB drive yet."
    exit 1
fi

# --- Save timestamp for 24h interval lock only after verified export ---
date +%s > "$LASTRUN_FILE"
log "INFO: Last successful run saved. Next run earliest in 24h."

exit 0
