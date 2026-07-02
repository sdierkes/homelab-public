# TrueNAS USB Backup — USB/UAS Troubleshooting and Recovery

> **Scope**
> This document describes a real-world failure mode seen with an external USB hard drive used as a removable ZFS backup pool on TrueNAS SCALE. The root cause was not the ZFS replication task itself, but an unstable USB Attached SCSI (`uas`) path through a USB-to-SATA bridge. The mitigation was to disable UAS for the affected USB bridge and force the older `usb-storage` driver instead.

---

## 1. Possible Symptoms

You may have this problem if your automated USB backup appears to work for a while, but after several runs you see one or more of the following symptoms.

### ZFS reports permanent metadata errors

```text
pool: backup-usb
state: ONLINE
status: One or more devices has experienced an error resulting in data
        corruption. Applications may be affected.

errors: Permanent errors have been detected in the following files:

        <metadata>:<0x0>
        <metadata>:<0x3d>
```

### ZFS device counters may still look clean

The pool can show `READ`, `WRITE`, and `CKSUM` counters as `0`, while still reporting permanent metadata errors:

```text
NAME        STATE   READ WRITE CKSUM
backup-usb ONLINE     0     0     0
```

Do not ignore this. Permanent `<metadata>` errors on a single-disk ZFS pool are serious because ZFS has no redundant copy from which it can repair the damaged metadata.

### Kernel logs show UAS aborts, USB resets, or I/O errors

Typical `dmesg` symptoms look like this:

```text
uas_eh_abort_handler
uas_eh_device_reset_handler start
reset SuperSpeed USB device
I/O error, dev sdh, sector 2056
I/O error, dev sdh, sector 2072
Synchronize Cache(10) failed
```

This strongly suggests a USB transport problem, especially if SMART does not show media errors.

### SMART looks healthy

The disk itself may still look healthy:

```text
SMART overall-health self-assessment test result: PASSED
Reallocated_Sector_Ct: 0
Current_Pending_Sector: 0
Offline_Uncorrectable: 0
UDMA_CRC_Error_Count: 0
SMART Error Log: No Errors Logged
```

This combination is typical for a USB bridge / UAS / cable / enclosure / passthrough issue rather than a classic bad-sector disk failure.

---

## 2. Why This Happens

Many external USB hard drive enclosures use a USB-to-SATA bridge. On Linux, such devices are often driven by `uas` — USB Attached SCSI.

UAS can provide better performance than the older `usb-storage` driver, but some bridge chips, enclosures, firmware versions, cables, power supplies, or virtualization passthrough combinations are unstable under sustained ZFS workloads.

This is especially relevant when TrueNAS runs as a VM and the USB disk is passed through to the guest.

The problematic path may look like this:

```text
TrueNAS VM
  → USB passthrough
  → UAS driver
  → USB-to-SATA bridge
  → external HDD
  → single-disk ZFS pool
```

A short USB reset at the wrong time can corrupt a single-disk ZFS backup pool. ZFS detects the corruption, but it cannot repair it without redundancy.

---

## 3. Confirm the Problem

### 3.1 Identify the USB disk and bridge

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
sudo dmesg -T | egrep -i 'usb|uas|reset|I/O error|failed|sense|cache' | tail -n 200
```

Look for lines like:

```text
usb 3-1: New USB device found, idVendor=174c, idProduct=55aa
usb 3-1: Product: USB3.1 Storage Device
usb 3-1: SerialNumber: ZXA0PGH7
scsi host9: uas
```

In this example, the USB bridge is:

```text
Vendor ID:  174c
Product ID: 55aa
```

The combined ID is:

```text
174c:55aa
```

### 3.2 Check ZFS pool health

```bash
sudo zpool status -v backup-usb
sudo zpool events -v | tail -n 120
```

If you see permanent metadata errors, do not continue using the pool for backups until you have fixed the USB path.

### 3.3 Check the disk with SMART

```bash
sudo smartctl -a /dev/sdX
sudo smartctl -a -d sat /dev/sdX
```

Replace `sdX` with the current device name of the USB disk.

Useful indicators:

```text
Reallocated_Sector_Ct
Current_Pending_Sector
Offline_Uncorrectable
UDMA_CRC_Error_Count
SMART Error Log
```

If these are clean while `dmesg` shows UAS resets and I/O errors, the transport path is the prime suspect.

---

## 4. Immediate Safety Actions

If a scrub or replication job is currently running while the USB path is producing resets or I/O errors, stop using the pool until the problem is understood.

If the pool is imported and no replication is running:

```bash
sudo sync
sudo zpool export backup-usb
```

If a scrub is running and the USB path is unstable:

```bash
sudo zpool scrub -s backup-usb
sudo sync
sudo zpool export backup-usb
```

Then power off or disconnect the drive only after the pool has been exported.

Checkpoint:

```bash
sudo zpool list
sudo zpool status backup-usb 2>&1 || true
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
```

Expected result:

```text
backup-usb is not listed by zpool list
cannot open 'backup-usb': no such pool
```

The block device may still be visible in `lsblk`; that is fine as long as the pool is not imported.

---

## 5. Disable UAS for the Affected USB Bridge

The goal is to force Linux to use `usb-storage` instead of `uas` for this specific USB bridge.

This example uses bridge ID `174c:55aa`. 

**Replace it with your own ID !**

### 5.1 Create a persistent source file on your data pool

On TrueNAS SCALE, manual files under `/etc` may not be reliable across updates. Store the desired configuration on your data pool, for example in `/mnt/zdata/scripts`:

```bash
sudo mkdir -p /mnt/zdata/scripts/

sudo tee /mnt/zdata/scripts/usb-storage-quirks.conf >/dev/null <<'EOF'
# Disable UAS for USB-SATA bridge
# Reason: repeated uas_eh_abort_handler / USB resets / I/O errors with backup-usb
options usb-storage quirks=174c:55aa:u
EOF

sudo chmod 0644 /mnt/zdata/scripts/usb-storage-quirks.conf
```
**Replace quirks=174c:55aa:u with your ID !**

Checkpoint:

```bash
cat /mnt/zdata/scripts/usb-storage-quirks.conf
```

Expected:

```text
options usb-storage quirks=174c:55aa:u
```

### 5.2 Install the active modprobe configuration

```bash
sudo cp /mnt/zdata/scripts/usb-storage-quirks.conf /etc/modprobe.d/usb-storage-quirks.conf
sudo chmod 0644 /etc/modprobe.d/usb-storage-quirks.conf
cat /etc/modprobe.d/usb-storage-quirks.conf
```

### 5.3 Add a Post Init restore script

Create a script that restores the file during boot:

```bash
sudo tee /mnt/zdata/scripts/restore-usb-storage-quirks.sh >/dev/null <<'EOF'
#!/bin/sh
set -eu

SRC="/mnt/zdata/scripts/usb-storage-quirks.conf"
DST="/etc/modprobe.d/usb-storage-quirks.conf"

if [ ! -f "$SRC" ]; then
  echo "ERROR: Source file not found: $SRC" >&2
  exit 1
fi

cp "$SRC" "$DST"
chmod 0644 "$DST"

echo "USB storage quirks restored to $DST"
EOF

sudo chmod +x /mnt/zdata/scripts/restore-usb-storage-quirks.sh
```

Checkpoint:

```bash
ls -l /mnt/zdata/scripts/restore-usb-storage-quirks.sh
cat /etc/modprobe.d/usb-storage-quirks.conf
```

### 5.4 Add the script in the TrueNAS GUI

Navigate to:

```text
System Settings
→ Advanced
→ Init/Shutdown Scripts
→ Add
```

Use:

```text
Type: Command
When: Post Init
Command: /mnt/zdata/scripts/restore-usb-storage-quirks.sh
Enabled: yes
Timeout: 10
```

### 5.5 Reboot TrueNAS

Keep the USB backup drive powered off or disconnected during reboot.

```bash
sudo reboot
```

After reboot, verify:

```bash
cat /etc/modprobe.d/usb-storage-quirks.conf
lsmod | egrep '(^uas|^usb_storage|^usbcore)' || true
sudo zpool list
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
```

The USB disk should not be connected yet.

---

## 6. Verify That UAS Is Disabled

Now connect or power on the USB drive.

Wait 30–60 seconds and run:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
lsmod | egrep '(^uas|^usb_storage|^usbcore)' || true
sudo dmesg -T | tail -n 120
```

The important lines are:

```text
usb 3-1: UAS is ignored for this device, using usb-storage instead
usb-storage 3-1:1.0: Quirks match for vid 174c pid 55aa
scsi host9: usb-storage 3-1:1.0
```

It is not a problem if the `uas` module is still loaded globally. What matters is that this specific device is bound through `usb-storage`, not UAS.

---

## 7. Stability Tests Before Reusing the Disk

Do not import the pool yet.

### 7.1 Short read test

```bash
sudo dmesg -C
sudo dd if=/dev/sdX of=/dev/null bs=4M count=1024 status=progress
sudo dmesg -T | egrep -i 'sdX|usb|uas|reset|I/O error|failed|medium|sense|cache' | tail -n 120
```

Replace `sdX` with the actual device.

Expected:

```text
1024+0 records in
1024+0 records out
```

And no new USB resets or I/O errors.

### 7.2 Longer read test

```bash
sudo dmesg -C
sudo dd if=/dev/sdX of=/dev/null bs=16M count=8192 status=progress
sudo dmesg -T | egrep -i 'sdX|usb|uas|reset|I/O error|failed|medium|sense|cache' | tail -n 120
```

This reads 128 GiB.

Expected: no USB resets, no I/O errors.

### 7.3 SMART short test

```bash
sudo smartctl -t short /dev/sdX
sleep 180
sudo smartctl -a /dev/sdX | egrep -A20 'SMART Self-test log|Num|# 1'
```

Expected:

```text
Short offline       Completed without error
```

---

## 8. If the Pool Already Has Metadata Errors

If the existing backup pool has permanent ZFS metadata errors, the safest option is usually to recreate the backup pool and run a fresh initial replication.

A single-disk ZFS backup pool cannot repair corrupted metadata by itself.

### 8.1 Export the pool

```bash
sudo zpool export backup-usb
```

### 8.2 Identify the correct disk

Use stable `by-id` names:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT
ls -l /dev/disk/by-id/ | egrep 'YOUR_SERIAL|usb'
```

Example:

```bash
DISK="/dev/disk/by-id/usb-HD26000N_XXXX-0:0"
PART="/dev/disk/by-id/usb-HD26000N_XXXX-0:0-part1"

echo "DISK=$DISK -> $(readlink -f "$DISK")"
echo "PART=$PART -> $(readlink -f "$PART")"
```

### 8.3 Clear the old ZFS label and partition table

This is destructive for the selected USB disk.

```bash
sudo zpool labelclear -f "$PART"
sudo zpool import
sudo wipefs -n "$DISK"
sudo wipefs -n "$PART" 2>/dev/null || true
```

If the old pool is no longer importable and only GPT/PMBR remain:

```bash
sudo wipefs -a "$DISK"
sudo partprobe "$DISK" 2>/dev/null || true
sleep 3
```

Checkpoint:

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINT "$DISK"
sudo wipefs -n "$DISK"
sudo zpool import
```

Expected:

```text
no pools available to import
```

### 8.4 Create a fresh pool

```bash
sudo zpool create \
  -f \
  -o ashift=12 \
  -o autotrim=off \
  -O acltype=posixacl \
  -O xattr=sa \
  -O compression=lz4 \
  -O atime=off \
  -O mountpoint=/backup-usb \
  -R /mnt \
  backup-usb "$DISK"
```

Checkpoint:

```bash
sudo zpool status -v backup-usb
sudo zpool list backup-usb
sudo zfs list -r backup-usb
```

Expected:

```text
state: ONLINE
errors: No known data errors
```

---

## 9. Write Test on the New Pool

Before running an initial replication, do a small write test.

### 9.1 Quick functional test

This test uses zeros and may be compressed by ZFS, so it is not a realistic performance test.

```bash
sudo dmesg -C
sudo dd if=/dev/zero of=/mnt/backup-usb/.usb-write-test bs=16M count=2048 status=progress conv=fsync
sudo dd if=/mnt/backup-usb/.usb-write-test of=/dev/null bs=16M status=progress
sudo rm /mnt/backup-usb/.usb-write-test
sudo sync
sudo zpool status -v backup-usb
sudo dmesg -T | egrep -i 'sdX|usb|uas|reset|I/O error|failed|medium|sense|cache' | tail -n 120
```

### 9.2 More realistic random-data test

```bash
sudo zfs create backup-usb/test
sudo zfs set compression=off backup-usb/test
sudo zfs get compression backup-usb/test

sudo dmesg -C
sudo dd if=/dev/urandom of=/mnt/backup-usb/test/random-test.bin bs=16M count=1024 status=progress conv=fsync
sudo dd if=/mnt/backup-usb/test/random-test.bin of=/dev/null bs=16M status=progress

sudo zfs destroy backup-usb/test
sudo sync

sudo zpool status -v backup-usb
sudo dmesg -T | egrep -i 'sdX|usb|uas|reset|I/O error|failed|medium|sense|cache' | tail -n 120
```

Expected:

```text
errors: No known data errors
```

and no new USB resets or I/O errors.

---

## 10. Run the Initial Replication Again

If the target pool was recreated, the existing replication task may need `allow_from_scratch=true` for the new initial run.

Check the task:

```bash
midclt call replication.get_instance 4 | jq '{
  id,
  name,
  enabled,
  auto,
  source_datasets,
  target_dataset,
  recursive,
  allow_from_scratch,
  readonly,
  retention_policy,
  state
}'
```

Temporarily enable from-scratch replication:

```bash
midclt call replication.update 4 '{"enabled": true, "allow_from_scratch": true}'
```

Start the job:

```bash
JOB_ID=$(midclt call replication.run 4)
echo "JOB_ID=$JOB_ID"
```

Monitor:

```bash
watch -n 30 "midclt call core.get_jobs | jq '.[] | select(.id == $JOB_ID) | {id,method,state,progress,error,exception,logs_path}'"
```

Also watch for USB errors:

```bash
sudo dmesg -T | egrep -i 'sdX|usb|uas|reset|I/O error|failed|medium|sense|cache' | tail -n 120
```

After a successful initial run, reset the task:

```bash
midclt call replication.update 4 '{"enabled": false, "allow_from_scratch": false}'
```

Then export:

```bash
sudo zpool status -v backup-usb
sudo sync
sudo zpool export backup-usb
```

---

## 11. Hardening the Automation Script

The automation script should not start replication just because the USB drive is visible. It should also verify that the pool is importable, imported, and healthy.

### Required safety checks

Before starting `replication.run`, add a hard pool-health gate:

```bash
POOL_HEALTH="$(zpool status -x "$ZPOOL_NAME" 2>&1 || true)"

if ! echo "$POOL_HEALTH" | grep -q "pool '$ZPOOL_NAME' is healthy"; then
  log "ERROR: ZPool '$ZPOOL_NAME' is not healthy — replication will NOT be started."
  zpool status -v "$ZPOOL_NAME" >> "$LOGFILE" 2>&1
  exit 1
fi
```

Also consider waiting until the pool is actually visible to ZFS before importing:

```bash
POOL_VISIBLE=0

for i in $(seq 1 18); do
  if zpool list -H -o name 2>/dev/null | grep -qx "$ZPOOL_NAME"; then
    log "INFO: ZPool '$ZPOOL_NAME' is already imported."
    POOL_VISIBLE=1
    break
  fi

  if zpool import 2>/dev/null | grep -q "pool: $ZPOOL_NAME"; then
    log "INFO: ZPool '$ZPOOL_NAME' is importable."
    POOL_VISIBLE=1
    break
  fi

  log "INFO: USB visible, but ZPool '$ZPOOL_NAME' not importable yet — waiting 10s..."
  sleep 10
done

if [ "$POOL_VISIBLE" -ne 1 ]; then
  log "ERROR: USB drive visible, but ZPool '$ZPOOL_NAME' was not found after waiting — aborting."
  exit 1
fi
```

---

## 12. Post-Fix Monitoring

After applying the UAS workaround and rebuilding the pool, test again after several real backup runs.

Recommended checks after the first 2–5 runs:

```bash
sudo zpool status -v backup-usb
sudo zpool events -v | tail -n 120
sudo dmesg -T | egrep -i 'sdX|usb|uas|reset|I/O error|failed|medium|sense|cache|Synchronize Cache' | tail -n 200
sudo smartctl -a /dev/sdX
```

A healthy result should include:

```text
errors: No known data errors
```

and no new USB resets or I/O errors.

If the errors return even with UAS disabled, replace the USB enclosure/dock, cable, power supply, or avoid USB passthrough and use SATA/HBA/controller passthrough instead.

---

## 13. Summary

The key lesson is:

```text
A successful ZFS replication job does not prove that the USB transport path is healthy.
```

Always check the target pool and the kernel logs after several runs. If UAS-related resets or I/O errors appear, fix the USB path before trusting the backup pool.
