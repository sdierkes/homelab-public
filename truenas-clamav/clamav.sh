#!/bin/sh
# ClamAV simple scan script (run-parts compatible)
# - Deletes old scan.log before running
# - Appends start/end info + infected files to scan-summary.log
# - Updates definitions and runs a recursive scan
# - Logs only to local files (no console output, no syslog)

set -e

# === Configuration ===
SCAN_DIR="/scandir"
CLAMSCAN_BIN="/usr/bin/clamscan"

# Host-mounted paths (adjust as needed)
LOG_BASE="/opt/host/var/log/clamav"
FRESHCLAM_LOG="$LOG_BASE/freshclam.log"
SCAN_LOG="$LOG_BASE/scan.log"
SUMMARY_LOG="$LOG_BASE/scan-summary.log"
DATA_DIR="/opt/host/var/lib/clamav"

# === Ensure log directory exists ===
mkdir -p "$LOG_BASE"

# === Delete old scan log (only this one) ===
[ -f "$SCAN_LOG" ] && rm -f "$SCAN_LOG"

# === Start Notification ===
START_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
{
    echo "==========================================================="
    echo "[$START_TIME] Starting ClamAV update and scan..."
} >> "$SUMMARY_LOG"
echo "[$START_TIME] Starting ClamAV update and scan..." >> "$SCAN_LOG"

# === Update Definitions ===
if command -v freshclam >/dev/null 2>&1; then
    echo "[$(date)] Updating ClamAV definitions..." >> "$FRESHCLAM_LOG"
    if ! freshclam --log="$FRESHCLAM_LOG" --datadir="$DATA_DIR" >> "$FRESHCLAM_LOG" 2>&1; then
        freshclam --log="$FRESHCLAM_LOG" >> "$FRESHCLAM_LOG" 2>&1 || \
        echo "[$(date)] Warning: freshclam update failed" >> "$SCAN_LOG"
    fi
else
    echo "[$(date)] freshclam not found in container" >> "$SCAN_LOG"
fi

# === Run Scan ===
echo "[$(date)] Starting ClamAV scan in $SCAN_DIR..." >> "$SCAN_LOG"

$CLAMSCAN_BIN -r --infected --verbose \
  --exclude='(?i)\.(jpg|jpeg|png|gif|bmp|tiff|svg|mp3|wav|flac|ogg|mp4|mkv|avi|mov|wmv|flv|mpg|mpeg)$' \
  --log="$SCAN_LOG" "$SCAN_DIR" >> "$SCAN_LOG" 2>&1

# === Extract infected files (if any) ===
INFECTED_COUNT=$(grep -c "FOUND" "$SCAN_LOG" || true)

if [ "$INFECTED_COUNT" -gt 0 ]; then
    {
        echo "[$(date)] Infected files detected ($INFECTED_COUNT):"
        grep "FOUND" "$SCAN_LOG" | sed 's/^/    /'
    } >> "$SUMMARY_LOG"
else
    echo "[$(date)] No infected files found." >> "$SUMMARY_LOG"
fi

# === End Notification ===
END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
{
    echo "[$END_TIME] ClamAV scan complete."
    echo ""
} >> "$SUMMARY_LOG"
echo "[$END_TIME] ClamAV scan complete." >> "$SCAN_LOG"

exit 0
