#!/bin/bash
# =============================================================================
# usb-backup.sh — Automated USB Backup for TrueNAS Scale
# =============================================================================
# Runs via cron every 10 minutes.
# Detects USB drive by serial number, imports ZPool backup-usb,
# starts replication task (ID 4), exports pool afterward.
# Enforces a minimum 24h interval between runs.
# =============================================================================

# --- Configuration ---
USB_SERIAL="ZXA0PGH7"            # Serial number of the USB drive
ZPOOL_NAME="backup-usb"           # Name of the USB ZPool
ZPOOL_ALTROOT="/mnt"              # TrueNAS mounts ZPools under /mnt
REPLICATION_ID=4                  # TrueNAS Replication Task ID
LOCKFILE="/var/run/usb-backup.lock"        # Prevents parallel execution
LASTRUN_FILE="/var/db/usb-backup.lastrun"  # Timestamp of last successful run
MIN_INTERVAL=$((24 * 3600))       # 24h in seconds
LOGFILE="/var/log/usb-backup.log"

# --- Logging ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOGFILE"
}

# --- Lock file check (prevent parallel runs) ---
if [ -e "$LOCKFILE" ]; then
    PID=$(cat "$LOCKFILE")
    if kill -0 "$PID" 2>/dev/null; then
        log "INFO: Script already running (PID $PID), exiting."
        exit 0
    else
        log "WARN: Stale lock file found, removing."
        rm -f "$LOCKFILE"
    fi
fi

# --- 24h interval check ---
if [ -f "$LASTRUN_FILE" ]; then
    LAST=$(cat "$LASTRUN_FILE")
    NOW=$(date +%s)
    DIFF=$(( NOW - LAST ))
    if [ "$DIFF" -lt "$MIN_INTERVAL" ]; then
        REMAINING=$(( MIN_INTERVAL - DIFF ))
        log "INFO: Last run was $(( DIFF / 3600 ))h $(( (DIFF % 3600) / 60 ))m ago – next run in $(( REMAINING / 3600 ))h $(( (REMAINING % 3600) / 60 ))m."
        exit 0
    fi
fi

# --- Check if USB drive is present ---
USB_DEV=$(lsblk -o NAME,SERIAL -d 2>/dev/null | awk -v serial="$USB_SERIAL" '$2 == serial {print $1}')
if [ -z "$USB_DEV" ]; then
    log "INFO: USB drive (Serial: $USB_SERIAL) not found – skipping."
    exit 0
fi
log "INFO: USB drive found: /dev/$USB_DEV (Serial: $USB_SERIAL)"

# --- Set lock file ---
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"; log "INFO: Lock file removed."' EXIT

# --- Import ZPool if not already imported ---
if zpool list "$ZPOOL_NAME" > /dev/null 2>&1; then
    log "INFO: ZPool '$ZPOOL_NAME' is already imported."
    POOL_WAS_IMPORTED=1
else
    log "INFO: Importing ZPool '$ZPOOL_NAME' (altroot: $ZPOOL_ALTROOT)..."
    if ! zpool import -R "$ZPOOL_ALTROOT" "$ZPOOL_NAME" >> "$LOGFILE" 2>&1; then
        log "ERROR: ZPool import failed – aborting."
        exit 1
    fi
    POOL_WAS_IMPORTED=0
    log "INFO: ZPool '$ZPOOL_NAME' successfully imported."
fi

# --- Enable replication task ---
log "INFO: Enabling Replication Task ID $REPLICATION_ID..."
if ! midclt call replication.update "$REPLICATION_ID" '{"enabled": true}' >> "$LOGFILE" 2>&1; then
    log "ERROR: Failed to enable replication task."
    [ "$POOL_WAS_IMPORTED" -eq 0 ] && zpool export "$ZPOOL_NAME"
    exit 1
fi

# --- Start replication task ---
log "INFO: Starting Replication Task ID $REPLICATION_ID..."
JOB_ID=$(midclt call replication.run "$REPLICATION_ID" 2>&1)
if [ $? -ne 0 ]; then
    log "ERROR: Failed to start replication task: $JOB_ID"
    midclt call replication.update "$REPLICATION_ID" '{"enabled": false}' >> "$LOGFILE" 2>&1
    [ "$POOL_WAS_IMPORTED" -eq 0 ] && zpool export "$ZPOOL_NAME"
    exit 1
fi
log "INFO: Replication job started, Job-ID: $JOB_ID"

# --- Disable replication task immediately after start ---
log "INFO: Disabling Replication Task ID $REPLICATION_ID again..."
midclt call replication.update "$REPLICATION_ID" '{"enabled": false}' >> "$LOGFILE" 2>&1

# --- Wait for job completion ---
log "INFO: Waiting for replication job to complete (ID: $JOB_ID)..."
MAX_WAIT=$((8 * 3600))  # maximum wait time: 8h
ELAPSED=0
SLEEP_INTERVAL=30

while true; do
    STATUS=$(midclt call core.get_jobs 2>/dev/null | python3 -c "
import sys, json
try:
    jobs = json.load(sys.stdin)
    for j in jobs:
        if j['id'] == $JOB_ID:
            print(j['state'])
            break
except:
    print('UNKNOWN')
" 2>/dev/null)

    case "$STATUS" in
        SUCCESS)
            log "INFO: Replication job completed successfully."
            break
            ;;
        FAILED|ABORTED)
            log "ERROR: Replication job failed (state: $STATUS)."
            zpool export "$ZPOOL_NAME" >> "$LOGFILE" 2>&1
            exit 1
            ;;
        RUNNING|WAITING)
            log "INFO: Job still running (state: $STATUS, elapsed: ${ELAPSED}s)..."
            ;;
        *)
            log "WARN: Unknown state: '$STATUS' – retrying..."
            ;;
    esac

    if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then
        log "ERROR: Timeout after ${MAX_WAIT}s – aborting."
        zpool export "$ZPOOL_NAME" >> "$LOGFILE" 2>&1
        exit 1
    fi

    sleep "$SLEEP_INTERVAL"
    ELAPSED=$(( ELAPSED + SLEEP_INTERVAL ))
done

# --- Export ZPool ---
log "INFO: Exporting ZPool '$ZPOOL_NAME'..."
sync
if zpool export "$ZPOOL_NAME" >> "$LOGFILE" 2>&1; then
    log "INFO: ZPool '$ZPOOL_NAME' successfully exported. Drive can be powered off."
else
    log "WARN: ZPool export failed – pool may still be in use."
fi

# --- Save timestamp for 24h interval lock ---
date +%s > "$LASTRUN_FILE"
log "INFO: Last successful run saved. Next run earliest in 24h."

exit 0
