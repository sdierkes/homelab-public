# TrueNAS USB Backup — Setup & Automation Guide

> **ℹ️ Info** Overview
> This guide describes how to set up an automated USB backup on TrueNAS Scale using ZFS replication. A daily snapshot of the main pool (`zdata`) is replicated to an external USB drive (`backup-usb`). A shell script monitors the USB drive and triggers the replication automatically when the drive is connected.

---

## Prerequisites

- TrueNAS Scale (tested on 25.10.4 Goldeye)
- External USB hard drive (≥ size of source pool)
- SSH access with `truenas_admin` user and `sudo` privileges
- Source ZPool: `zdata` (adjust to your pool name)

---

## 1. Create a ZPool on the External USB Drive

### GUI

1. Navigate to **Storage → Create Pool**
2. Click **Create Pool**
3. Enter pool name: `backup-usb`
4. Under **Data**, click **Add Vdev → Disk**
5. Select your USB disk (identify by size/serial)
6. Layout: `Stripe` (single disk)
7. Click **Save And Go To Review → Create Pool**

> **⚠️ Warning**
> Make sure you select the correct disk. All data on it will be erased.

### Console

```bash
# List available disks to identify USB drive
lsblk -o NAME,SIZE,SERIAL,TRAN,MODEL

# Identify USB disk (look for TRAN=usb)
lsblk -o NAME,SERIAL,TRAN,SIZE | grep usb

# Note the device name (e.g. sdh) and create pool
# Replace 'sdh' with your actual device
sudo zpool create -f -o ashift=12 backup-usb /dev/sdh

# Verify pool
zpool list backup-usb
zpool status backup-usb
```

> **💡 Tip** Finding the USB Serial Number
> Note the serial number — you will need it for the automation script later:
> ```bash
> lsblk -o NAME,SERIAL,TRAN | grep usb
> ```

---

## 2. Create a Daily Snapshot Task

### GUI

1. Navigate to **Data Protection → Periodic Snapshot Tasks → Add**
2. Configure:
   - **Dataset**: `zdata` (recursive ✅)
   - **Naming Schema**: `auto-%Y-%m-%d_%H-%M`
   - **Schedule**: Daily at 02:00
   - **Lifetime**: 2 weeks (adjust to preference)
   - **Enabled**: ✅
3. Click **Save**

### Console

```bash
# Create snapshot task via midclt
midclt call pool.snapshottask.create '{
  "dataset": "zdata",
  "recursive": true,
  "lifetime_value": 14,
  "lifetime_unit": "DAY",
  "naming_schema": "auto-%Y-%m-%d_%H-%M",
  "schedule": {
    "minute": "0",
    "hour": "2",
    "dom": "*",
    "month": "*",
    "dow": "*"
  },
  "enabled": true
}'

# Verify
midclt call pool.snapshottask.query | python3 -c "
import sys, json
tasks = json.load(sys.stdin)
for t in tasks:
    print(f'ID: {t[\"id\"]} | Dataset: {t[\"dataset\"]} | Schema: {t[\"naming_schema\"]} | Enabled: {t[\"enabled\"]}')
"
```

---

## 3. Create a Replication Task

> **❗ Important**
> Set the task to **disabled** — the automation script will enable/disable it on each run. This prevents accidental automatic runs when the USB drive is not connected.

### GUI

1. Navigate to **Data Protection → Replication Tasks → Add**
2. Configure:
   - **Source Location**: On this System
   - **Destination Location**: On this System
   - **Source Dataset**: `zdata` (recursive ✅)
   - **Destination Dataset**: `backup-usb/zdata`
   - **Replication Schedule**: *(leave empty / disabled)*
   - **Naming Schema**: `auto-%Y-%m-%d_%H-%M`
   - **Also Include Naming Schema**: `auto-%Y-%m-%d_%H-%M`
   - **Enabled**: ❌ *(intentionally disabled)*
3. Click **Save**
4. Note the **Task ID** shown in the task list — you need it for the script.

### Console

```bash
# Create replication task (disabled)
midclt call replication.create '{
  "name": "zdata - backup-usb/zdata",
  "direction": "PUSH",
  "transport": "LOCAL",
  "source_datasets": ["zdata"],
  "target_dataset": "backup-usb/zdata",
  "recursive": true,
  "also_include_naming_schema": ["auto-%Y-%m-%d_%H-%M"],
  "retention_policy": "SOURCE",
  "large_block": true,
  "compressed": true,
  "embed": false,
  "retries": 5,
  "enabled": false
}'

# Get Task ID — note it for the script
midclt call replication.query | python3 -c "
import sys, json
tasks = json.load(sys.stdin)
for t in tasks:
    print(f'ID: {t[\"id\"]} | Name: {t[\"name\"]} | Enabled: {t[\"enabled\"]}')
"
```

---

## 4. Initial Manual Replication Run

### GUI

> **⚠️ Warning** Task is disabled — enable it first
> Since the replication task is intentionally disabled (see step 3), the **▶ Run Now** button will not work directly. Follow these steps:

1. Navigate to **Data Protection → Replication Tasks**
2. Click the **✏️ Edit** button on your replication task
3. Check **Enabled** ✅ and click **Save**
4. Click **▶ Run Now** next to the task
5. Monitor progress in **Tasks → Jobs**
6. Once the job is finished, **edit the task again** and uncheck **Enabled** ❌ — click **Save**

### Console

```bash
# Get your replication task ID
REPL_ID=$(midclt call replication.query | python3 -c "
import sys, json
tasks = json.load(sys.stdin)
for t in tasks:
    if 'backup-usb' in t['name']:
        print(t['id'])
" )
echo "Replication Task ID: $REPL_ID"

# Enable temporarily and run
midclt call replication.update "$REPL_ID" '{"enabled": true}'
JOB_ID=$(midclt call replication.run "$REPL_ID")
echo "Job ID: $JOB_ID"

# Disable again immediately
midclt call replication.update "$REPL_ID" '{"enabled": false}'

# Monitor job progress
watch -n 10 "midclt call core.get_jobs | python3 -c \"
import sys, json
jobs = json.load(sys.stdin)
for j in jobs:
    if j['id'] == $JOB_ID:
        p = j.get('progress', {})
        print(f'State: {j[\"state\"]}')
        print(f'Progress: {p.get(\"percent\", 0):.1f}%')
        print(f'Description: {p.get(\"description\", \"\")}')
\""
```

---

## 5. Verify Success

### GUI

1. Navigate to **Data Protection → Replication Tasks**
2. Check the **State** column — should show `FINISHED`
3. Navigate to **Tasks → Jobs** for detailed logs

### Console

```bash
# Check job result
midclt call core.get_jobs | python3 -c "
import sys, json
jobs = json.load(sys.stdin)
repl_jobs = [j for j in jobs if j['method'] == 'replication.run']
last = sorted(repl_jobs, key=lambda x: x['id'])[-1]
print(f'Job ID:    {last[\"id\"]}')
print(f'State:     {last[\"state\"]}')
print(f'Started:   {last[\"time_started\"]}')
print(f'Finished:  {last[\"time_finished\"]}')
print(f'Error:     {last.get(\"error\", \"none\")}')
"

# Verify datasets exist on USB pool
zfs list -r backup-usb/zdata | head -20

# Verify latest snapshot was replicated
zfs list -t snapshot -r backup-usb/zdata | tail -5
```

---

## 6. Test: Full Export / Disconnect / Reconnect / Import Cycle

### 6.1 Export USB Pool

```bash
# GUI: Storage → backup-usb → Export/Disconnect

# Console:
sudo zpool export backup-usb

# Verify pool is gone
zpool list backup-usb 2>/dev/null || echo "✅ Pool successfully exported"
```

### 6.2 Disconnect USB Drive

Physically unplug the USB drive or power it off.

```bash
# Verify device is gone
lsblk | grep -i usb || echo "✅ USB drive not detected"
```

### 6.3 Reconnect USB Drive

Power on / plug in the USB drive.

> **📝 Note** Detection may take a moment
> Depending on the drive, it can take **30–60 seconds** after powering on before the OS detects it. Run the command below repeatedly until the drive appears — do not proceed to 6.4 before the drive is listed.

```bash
# Verify device is detected (repeat until output appears)
lsblk -o NAME,SERIAL,TRAN,SIZE | grep usb
```

### 6.4 Import Pool

> **💡 Tip** GUI: Check drive availability first
> Before importing, confirm the drive is recognized by TrueNAS: navigate to **Storage** — the `backup-usb` pool should appear in the list with state **Exported**. If it does not appear yet, wait a few more seconds and refresh the page.

```bash
# GUI: Storage → backup-usb → Import Pool → select backup-usb

# Console — always use -R /mnt on TrueNAS:
sudo zpool import -R /mnt backup-usb

# Verify
zpool status backup-usb
```

### 6.5 Manual Replication Job

### GUI

> **📝 Note**
> The steps are identical to the initial run described in [Section 4](#4-initial-manual-replication-run): enable the task, click **▶ Run Now**, monitor in **Tasks → Jobs**, then disable the task again afterward.

### Console

```bash
# Get task ID
REPL_ID=$(midclt call replication.query | python3 -c "
import sys, json
tasks = json.load(sys.stdin)
for t in tasks:
    if 'backup-usb' in t['name']:
        print(t['id'])
")

# Enable, run, disable
midclt call replication.update "$REPL_ID" '{"enabled": true}'
JOB_ID=$(midclt call replication.run "$REPL_ID")
midclt call replication.update "$REPL_ID" '{"enabled": false}'
echo "Job ID: $JOB_ID"

# Wait for completion
while true; do
    STATE=$(midclt call core.get_jobs | python3 -c "
import sys, json
jobs = json.load(sys.stdin)
for j in jobs:
    if j['id'] == $JOB_ID:
        print(j['state'])
")
    echo "$(date '+%H:%M:%S') State: $STATE"
    [[ "$STATE" == "SUCCESS" || "$STATE" == "FAILED" ]] && break
    sleep 15
done

# Final result
[[ "$STATE" == "SUCCESS" ]] && echo "✅ Replication successful" || echo "❌ Replication failed"
```

---

## 7. Automation Script

> **ℹ️ Info**
> The script detects the USB drive by serial number, imports the pool, runs the replication task, and exports the pool afterward. A 24-hour lock prevents repeated runs if the drive stays connected.

### 7.1 Prerequisites Check

Before deploying the script, verify these values on your system:

```bash
# 1. USB drive serial number (with drive connected)
lsblk -o NAME,SERIAL,TRAN | grep usb
# → Note the SERIAL value, e.g. <USB_SERIAL>

# 2. Replication Task ID
midclt call replication.query | python3 -c "
import sys, json
tasks = json.load(sys.stdin)
for t in tasks:
    print(f'ID: {t[\"id\"]} | Name: {t[\"name\"]}')
"
# → Note the ID for your backup-usb task, e.g. 4

# 3. Source and target pool names
zpool list
# → Confirm 'zdata' and 'backup-usb' exist
```

### 7.2 The Script

> **Required before use**
> The script below is intentionally shipped with placeholders. Before running it, adjust at least:
>
> - `USB_SERIAL` — set this to the serial shown by `lsblk -o NAME,SERIAL,TRAN`
> - `REPLICATION_ID` — set this to your TrueNAS replication task ID
> - `ZPOOL_NAME` — adjust if your USB backup pool is not named `backup-usb`
>
> The script will refuse to run while `USB_SERIAL="CHANGE_ME_USB_SERIAL"` or `REPLICATION_ID=0` is still configured.

Save as `/mnt/zdata/scripts/usb-backup.sh`:

```bash
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

```

### 7.3 Install the Script

```bash
# Copy to scripts directory on your ZPool (survives TrueNAS updates)
mkdir -p /mnt/zdata/scripts
nano /mnt/zdata/scripts/usb-backup.sh
# → paste script content, then adjust USB_SERIAL, REPLICATION_ID, and ZPOOL_NAME if needed

chmod +x /mnt/zdata/scripts/usb-backup.sh

# Verify syntax before first run
bash -n /mnt/zdata/scripts/usb-backup.sh

# Verify placeholders have been replaced
grep -E 'CHANGE_ME_USB_SERIAL|REPLICATION_ID=0' /mnt/zdata/scripts/usb-backup.sh && echo "ERROR: script still contains placeholders" || echo "OK: required placeholders replaced"

# Verify
ls -la /mnt/zdata/scripts/usb-backup.sh
```

---

## 8. Test Script Manually

Before setting up the cron job, verify the script works correctly by running it manually.

### 8.1 Prerequisites

Before the first run, confirm that the script no longer contains placeholders:

```bash
grep -E 'CHANGE_ME_USB_SERIAL|REPLICATION_ID=0' /mnt/zdata/scripts/usb-backup.sh && echo "ERROR: configure the script first" || echo "OK: script appears configured"
```

```bash
# Ensure USB drive is connected and detected
lsblk -o NAME,SERIAL,TRAN,SIZE | grep usb

# Ensure pool is NOT yet imported (script should import it itself)
zpool list backup-usb 2>/dev/null && sudo zpool export backup-usb || echo "OK: Pool not imported - ready"

# Reset 24h lock if it exists from a previous run
sudo rm -f /var/db/usb-backup.lastrun
```

### 8.2 Run the Script

```bash
# Run in foreground so you can see output directly
sudo /mnt/zdata/scripts/usb-backup.sh

# Or run in background and follow the log
sudo /mnt/zdata/scripts/usb-backup.sh &
tail -f /var/log/usb-backup.log
```

### 8.3 Verify Success

```bash
# Check log for success message
grep -E 'ERROR|successfully exported|failed' /var/log/usb-backup.log | tail -10
```

Expected final lines in the log:

```
INFO: Replication job completed successfully.
INFO: ZPool 'backup-usb' successfully exported. Drive can be powered off.
INFO: Last successful run saved. Next run earliest in 24h.
INFO: Lockfile removed.
```

### 8.4 Verify 24h Lock is Active

```bash
# Confirm lastrun file was written
cat /var/db/usb-backup.lastrun && echo "OK: 24h lock is set"

# Run script again - should exit immediately with 24h message
sudo /mnt/zdata/scripts/usb-backup.sh
tail -3 /var/log/usb-backup.log
# Expected: INFO: Last run was 0h Xm ago - next run in 23h Xm.
```

### 8.5 Verify Pool was Exported

```bash
# Pool should no longer be imported
zpool list backup-usb 2>/dev/null || echo "OK: Pool successfully exported by script"
```

> **💡 Tip**
> Only proceed to setting up the cron job once all checks above pass successfully.

---

## 9. Set Up Cron Job

### GUI

1. Navigate to **System → Advanced Settings → Cron Jobs → Add**
2. Configure:
   - **Description**: USB Backup Automation
   - **Command**: `/mnt/zdata/scripts/usb-backup.sh`
   - **Run As User**: `root`
   - **Schedule**: Custom — `*/10 * * * *` (every 10 minutes)
   - **Hide Standard Output**: ✅
   - **Hide Standard Error**: ✅
   - **Enabled**: ✅
3. Click **Save**

### Console

```bash
midclt call cronjob.create '{
  "user": "root",
  "command": "/mnt/zdata/scripts/usb-backup.sh",
  "description": "USB Backup Automation",
  "schedule": {
    "minute": "*/10",
    "hour": "*",
    "dom": "*",
    "month": "*",
    "dow": "*"
  },
  "enabled": true,
  "stdout": true,
  "stderr": true
}'

# Verify
midclt call cronjob.query | python3 -c "
import sys, json
jobs = json.load(sys.stdin)
for j in jobs:
    if 'usb-backup' in j.get('command', ''):
        print(f'ID: {j[\"id\"]} | Command: {j[\"command\"]} | Enabled: {j[\"enabled\"]}')
"
```

---

## 10. Test the Cron Automation

### 10.1 Reset 24h Lock and Trigger a Test Run

```bash
# Reset the 24h lock to allow immediate run
sudo rm -f /var/db/usb-backup.lastrun

# Ensure USB drive is connected and pool is NOT yet imported
zpool list backup-usb 2>/dev/null && sudo zpool export backup-usb

# Watch the log (cron will trigger within 10 minutes)
tail -f /var/log/usb-backup.log
```

### 10.2 Expected Log Output

```
2026-06-28 22:00:02 INFO: USB drive found: /dev/sdh (Serial: <USB_SERIAL>)
2026-06-28 22:00:02 INFO: Importing ZPool 'backup-usb' (altroot: /mnt)...
2026-06-28 22:00:42 INFO: ZPool 'backup-usb' successfully imported.
2026-06-28 22:00:42 INFO: Enabling Replication Task ID 4...
2026-06-28 22:00:42 INFO: Starting Replication Task ID 4...
2026-06-28 22:00:42 INFO: Replication job started, Job-ID: 15812
2026-06-28 22:00:42 INFO: Disabling Replication Task ID 4 again...
2026-06-28 22:00:43 INFO: Waiting for replication job to complete (ID: 15812)...
2026-06-28 22:00:43 INFO: Job still running (State: RUNNING, elapsed: 0s)...
2026-06-28 22:01:13 INFO: Replication job completed successfully.
2026-06-28 22:01:13 INFO: Exporting ZPool 'backup-usb'...
2026-06-28 22:01:13 INFO: ZPool 'backup-usb' successfully exported. Drive can be powered off.
2026-06-28 22:01:13 INFO: Last successful run saved. Next run earliest in 24h.
2026-06-28 22:01:13 INFO: Lockfile removed.
```

### 10.3 Test: Drive Left Connected (24h Lock)

```bash
# Leave the drive connected after a successful run
# Wait for next cron trigger (≤ 10 min), then check log:
tail -20 /var/log/usb-backup.log

# Expected output:
# INFO: Last run was 0h 8m ago — next run in 23h 52m.
```

### 10.4 Test: Drive Not Connected

```bash
# Power off / disconnect USB drive
# Wait for next cron trigger, then check log:
tail -5 /var/log/usb-backup.log

# Expected output:
# INFO: USB drive (Serial: <USB_SERIAL>) not found — skipping.
```

### 10.5 Test: Full Cron Run — Connect Drive and Observe

This is the final end-to-end test: reset the 24h lock, connect the drive, and let the cron job do everything automatically.

```bash
# Step 1 — Reset 24h lock
sudo rm -f /var/db/usb-backup.lastrun
echo "✅ 24h lock cleared"

# Step 2 — Ensure pool is not already imported
zpool list backup-usb 2>/dev/null && sudo zpool export backup-usb || echo "✅ Pool not imported"

# Step 3 — Power on / connect the USB drive
# (do this now, then wait for OS detection)

# Step 4 — Confirm drive is detected before watching log
lsblk -o NAME,SERIAL,TRAN,SIZE | grep usb

# Step 5 — Watch the log (cron triggers within ≤ 10 minutes)
tail -f /var/log/usb-backup.log
```

Expected log sequence:

```
INFO: USB drive found: /dev/sdh (Serial: <USB_SERIAL>)
INFO: Importing ZPool 'backup-usb' (altroot: /mnt)...
INFO: ZPool 'backup-usb' successfully imported.
INFO: Enabling Replication Task ID 4...
INFO: Starting Replication Task ID 4...
INFO: Replication job started, Job-ID: XXXXX
INFO: Disabling Replication Task ID 4 again...
INFO: Waiting for replication job to complete (ID: XXXXX)...
INFO: Job still running (State: RUNNING, elapsed: 0s)...
INFO: Replication job completed successfully.
INFO: Exporting ZPool 'backup-usb'...
INFO: ZPool 'backup-usb' successfully exported. Drive can be powered off.
INFO: Last successful run saved. Next run earliest in 24h.
INFO: Lockfile removed.
```

```bash
# After completion — verify pool was exported automatically
zpool list backup-usb 2>/dev/null || echo "✅ Pool exported by cron"

# Verify 24h lock is active
cat /var/db/usb-backup.lastrun && echo "✅ 24h lock set"

# Verify replication task is still disabled
midclt call replication.query | python3 -c "
import sys, json
tasks = json.load(sys.stdin)
for t in tasks:
    if 'backup-usb' in t['name']:
        print(f'Task enabled: {t[\"enabled\"]}')
"
# Expected: Task enabled: False
```

> **💡 Tip** All green?
> If all checks pass, the automation is fully working. From now on, simply power on the USB drive — the cron job will handle everything within 10 minutes and power off notification will appear in the log.

---

## 11. Post-Deployment Health Check After Several Runs

> **⚠️ Important**
> A replication job can complete successfully even when the USB transport path is unstable or the target pool has already recorded ZFS metadata errors. After the first few real backup runs, explicitly check the USB backup pool and kernel logs before trusting the routine.

Run these checks after the first **2–5 successful automated backup cycles**:

```bash
# Import the pool if it is currently exported
sudo zpool import -R /mnt backup-usb

# Check ZFS health
sudo zpool status -v backup-usb

# Check recent ZFS events
sudo zpool events -v | tail -n 120

# Check for USB/UAS/reset/I/O symptoms
sudo dmesg -T | egrep -i 'usb|uas|reset|I/O error|failed|medium|sense|cache|Synchronize Cache' | tail -n 200

# Check SMART health of the USB disk
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
sudo smartctl -a /dev/sdX
```

Replace `sdX` with the current device name of the USB drive.

A healthy result should show:

```text
errors: No known data errors
```

and **no new** kernel messages such as:

```text
uas_eh_abort_handler
reset SuperSpeed USB device
I/O error, dev sdX
Synchronize Cache(10) failed
```

If you see permanent ZFS metadata errors such as:

```text
Permanent errors have been detected in the following files:

        <metadata>:<0x0>
        <metadata>:<0x3d>
```

or repeated USB/UAS resets in `dmesg`, stop using the backup pool until the transport problem is fixed.

See the companion troubleshooting guide:

**[TrueNAS USB Backup — USB/UAS Troubleshooting and Recovery](truenas-usb-uas-troubleshooting.md)**

That document describes symptoms, analysis, the `usb-storage.quirks=...` UAS workaround, validation checkpoints, and the safe rebuild of the USB backup pool.


## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `cannot mount`: failed to create mountpoint | ZPool imported without `-R /mnt` | Always use `zpool import -R /mnt backup-usb` |
| `Task is not enabled` | Replication task disabled, wrong API call | Script handles this: enable → run → disable |
| Pool state `SUSPENDED` | Drive disconnected while pool was active | `sudo zpool clear backup-usb` then `zpool export backup-usb` |
| Repeated `uas_eh_abort_handler`, USB resets, `I/O error`, or `Synchronize Cache(10) failed` | USB-SATA bridge / UAS / cable / enclosure / passthrough instability | Disable UAS for the affected bridge or replace the enclosure/cable. See [USB/UAS Troubleshooting and Recovery](truenas-usb-uas-troubleshooting.md). |
| Permanent `<metadata>` errors in `zpool status -v` | USB/UAS reset, unsafe disconnect, or damaged single-disk backup pool metadata | Do **not** continue normal replication. See [USB/UAS Troubleshooting and Recovery](truenas-usb-uas-troubleshooting.md). If errors remain, rebuild the backup pool and run a fresh initial replication. |
| Script not executable | `/data` or `/usr/local` are read-only on TrueNAS | Store script under `/mnt/zdata/scripts/` |
| Cron job not running | Wrong user or path | Verify with `midclt call cronjob.query` |

---

## Log File Location

```bash
tail -f /var/log/usb-backup.log
```

> **📝 Note**
> The log file at `/var/log/usb-backup.log` is not persistent across TrueNAS reboots (it lives on tmpfs). For persistent logging, change `LOGFILE` in the script to `/mnt/zdata/scripts/usb-backup.log`.

---

*Last updated: 2026-07-02 | TrueNAS Scale 25.10.4 Goldeye*
