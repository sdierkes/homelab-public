#!/bin/sh
# ClamAV scan script (run-parts compatible)
# - daemon-based (clamd + clamdscan)
# - scan directory = $1 (required)
# - parallelism (MaxThreads) = $2 (optional, default 2)
# - per-directory log file names
# - rotates scan log (keep 5)
# - excludes media files
# - silent to console

set -e

### ====== PARAMS ======
SCAN_DIR="$1"
PARALLEL="$2"

# default parallelism
if [ -z "$PARALLEL" ]; then
    PARALLEL=2
fi

# make sure it's a positive integer
case "$PARALLEL" in
    ''|*[!0-9]*)
        PARALLEL=2
        ;;
    0)
        PARALLEL=2
        ;;
esac

### ====== PATHS / CONFIG ======
CLAMD_BIN="/usr/sbin/clamd"          # change to /usr/bin/clamd if needed
CLAMDSCAN_BIN="/usr/bin/clamdscan"
CLAMD_CONF="/etc/clamav/clamd.conf"
TMP_CLAMD_CONF="/tmp/clamd.conf"

LOG_BASE="/opt/host/var/log/clamav"
FRESHCLAM_LOG="$LOG_BASE/freshclam.log"
DATA_DIR="/opt/host/var/lib/clamav"

# check scan dir param
mkdir -p "$LOG_BASE"
if [ -z "$SCAN_DIR" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: no scan directory given" >> "$LOG_BASE/scan-error.log"
    exit 1
fi

# sanitize dir name for log file
SAN_DIR=$(echo "$SCAN_DIR" | sed 's#^/##' | tr '/.' '_-')
[ -z "$SAN_DIR" ] && SAN_DIR="root"

SCAN_LOG="$LOG_BASE/scan-$SAN_DIR.log"
SUMMARY_LOG="$LOG_BASE/scan-$SAN_DIR-summary.log"

# check directory exists
if [ ! -d "$SCAN_DIR" ]; then
    {
        echo "==========================================================="
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: scan directory '$SCAN_DIR' does not exist. Aborting."
    } >> "$SUMMARY_LOG"
    exit 1
fi

### ====== simple log rotation (keep 5) ======
rotate_log() {
    FILE="$1"
    [ -f "${FILE}.4" ] && rm -f "${FILE}.4"
    [ -f "${FILE}.3" ] && mv "${FILE}.3" "${FILE}.4"
    [ -f "${FILE}.2" ] && mv "${FILE}.2" "${FILE}.3"
    [ -f "${FILE}.1" ] && mv "${FILE}.1" "${FILE}.2"
    [ -f "${FILE}" ]   && mv "${FILE}"   "${FILE}.1"
}

rotate_log "$SCAN_LOG"

### ====== start summary ======
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
{
    echo "==========================================================="
    echo "[$START_TIME] Starting ClamAV daemon scan for: $SCAN_DIR"
    echo "[$START_TIME] Parallelism (MaxThreads): $PARALLEL"
} >> "$SUMMARY_LOG"

echo "[$START_TIME] Starting ClamAV daemon scan for: $SCAN_DIR (threads=$PARALLEL)" >> "$SCAN_LOG"

### ====== update definitions ======
if command -v freshclam >/dev/null 2>&1; then
    echo "[$(date)] Updating ClamAV definitions..." >> "$FRESHCLAM_LOG"
    if ! freshclam --log="$FRESHCLAM_LOG" --datadir="$DATA_DIR" >> "$FRESHCLAM_LOG" 2>&1; then
        echo "[$(date)] Warning: freshclam update failed" >> "$SCAN_LOG"
    fi
else
    echo "[$(date)] freshclam not found in container" >> "$SCAN_LOG"
fi

### ====== ensure clamd is running, start with our MaxThreads if not ======
if ! pgrep -x clamd >/dev/null 2>&1; then
    if [ -f "$CLAMD_CONF" ]; then
        cp "$CLAMD_CONF" "$TMP_CLAMD_CONF"
        if grep -q '^MaxThreads' "$TMP_CLAMD_CONF"; then
            sed -i "s/^MaxThreads.*/MaxThreads $PARALLEL/" "$TMP_CLAMD_CONF"
        else
            echo "MaxThreads $PARALLEL" >> "$TMP_CLAMD_CONF"
        fi
        "$CLAMD_BIN" -c "$TMP_CLAMD_CONF" >/dev/null 2>&1 &
    else
        "$CLAMD_BIN" >/dev/null 2>&1 &
    fi
    sleep 5
fi

### ====== run clamdscan (daemon, parallel, with exclusions) ======
echo "[$(date)] Running clamdscan in $SCAN_DIR..." >> "$SCAN_LOG"

$CLAMDSCAN_BIN --multiscan --infected --verbose \
  --log="$SCAN_LOG" \
  --exclude='(?i)\.(jpg|jpeg|png|gif|bmp|tiff|svg|mp3|wav|flac|ogg|aac|m4a|mp4|mkv|avi|mov|wmv|flv|webm)$' \
  "$SCAN_DIR" >> "$SCAN_LOG" 2>&1

### ====== summarize infections ======
INFECTED_COUNT=$(grep -c "FOUND$" "$SCAN_LOG" || true)

if [ "$INFECTED_COUNT" -gt 0 ]; then
    {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] Infected files detected ($INFECTED_COUNT):"
        grep "FOUND$" "$SCAN_LOG" | sed 's/^/    /'
    } >> "$SUMMARY_LOG"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] No infected files found." >> "$SUMMARY_LOG"
fi

### ====== end summary ======
END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
{
    echo "[$END_TIME] ClamAV daemon scan complete for: $SCAN_DIR"
    echo ""
} >> "$SUMMARY_LOG"
echo "[$END_TIME] ClamAV daemon scan complete for: $SCAN_DIR" >> "$SCAN_LOG"

exit 0
