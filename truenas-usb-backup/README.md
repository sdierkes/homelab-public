# TrueNAS USB Backup

## Motivation

Cloud backup services are convenient but come with recurring costs, bandwidth limitations, and the requirement to trust a third party with your data. For a homelab with several terabytes of irreplaceable data — family photos, videos, documents, local backups of VMs — an offline backup to an external USB drive is a simple, cost-effective, and privacy-preserving alternative.

The core idea is the **3-2-1 backup rule**:

- **3** copies of your data
- **2** different storage media
- **1** copy offsite (or at least offline / disconnected)

An external USB drive that is only powered on during the backup window and then stored away satisfies the "offline" requirement: it cannot be affected by ransomware, accidental deletion, or a failing NAS while it is disconnected.

---

## How It Works

TrueNAS SCALE uses **ZFS**, which has built-in support for snapshots and replication. The backup process works as follows:

1. A **daily snapshot** is taken of the source pool (`zdata`) at a fixed time (e.g. 02:00). A snapshot is a lightweight, point-in-time copy of the data — it uses no extra space at creation and only grows as data changes.

2. A **replication task** sends the snapshot to the USB pool (`backup-usb`). The first run transfers all data. Every subsequent run is **incremental** — only the blocks that changed since the last snapshot are transferred, making it fast and efficient.

3. A **shell script** running as a cron job every 10 minutes detects when the USB drive is powered on, imports the ZFS pool, triggers the replication task, and exports the pool again when done. A 24-hour lock prevents repeated runs if the drive stays connected.

4. Once the replication is complete, the pool is exported cleanly and the drive can be powered off and stored away.

> **ℹ️ Info** Want to understand snapshots and space usage in depth?
> See [truenas-zfs-snapshots-explained.md](truenas-zfs-snapshots-explained.md) for a detailed explanation of how ZFS snapshots work, what happens to disk space when files are added, modified, or deleted, and how to plan the required capacity for the backup drive.

---

## Prerequisites

### Technical

| Requirement | Details |
|---|---|
| TrueNAS SCALE | Tested on 25.10.4 Goldeye — earlier versions may differ in API calls |
| Source ZPool | A working ZPool with data to back up (e.g. `zdata`) |
| External USB drive | Capacity ≥ source data + ~20–30% overhead for snapshot history (see snapshot guide) |
| USB drive formatted as ZFS | The script creates and manages a ZPool (`backup-usb`) on the drive — the drive must not be pre-formatted as NTFS/exFAT/etc. |
| SSH access | Required to deploy the script and set up the cron job |
| `sudo` / root privileges | Required for `zpool` operations and cron job setup |

### Personal Knowledge

| Skill | Why it is needed |
|---|---|
| Basic Linux shell | Editing files, running commands, reading log output |
| TrueNAS web GUI | Navigating Storage, Data Protection, and System sections |
| Basic ZFS concepts | Understanding pools, datasets, snapshots — helps with troubleshooting |
| Reading log files | The script logs all activity; being able to interpret the output is essential |

> **📝 Note**
> You do **not** need deep ZFS expertise to follow this guide. All commands are provided ready to use. However, understanding the basics of what a pool and a snapshot are will help you recover confidently if something goes wrong.

---

## Risks and Limitations

> **⚠️ Warning** Read before you start

### Data Loss Risk on the USB Drive
The initial pool creation on the USB drive **erases all existing data** on it. Make sure you select the correct disk and that there is nothing on it you need.

### Single-Disk Pool — No Redundancy
The USB pool is a single-disk ZFS stripe (no mirror, no RAIDZ). If the USB drive fails, all backup data is lost. The drive is a backup of your NAS — not itself backed up. Consider rotating between two drives for additional safety.

### Unclean Disconnection Can Cause Pool Errors
If the USB drive is powered off while the pool is still imported (e.g. during a replication run), the pool may enter a `SUSPENDED` or degraded state. Always let the script complete and export the pool cleanly before disconnecting. The Troubleshooting section of the setup guide covers recovery steps.

### Snapshots Do Not Free Space Immediately
Deleting files on the live system does not release space on the backup drive as long as snapshots referencing those blocks exist. Depending on your retention policy and change rate, the backup drive can grow significantly over time. See [truenas-zfs-snapshots-explained.md](truenas-zfs-snapshots-explained.md) for details and capacity planning.

### Replication Task is Intentionally Disabled
The replication task is kept disabled in TrueNAS to prevent it from running automatically when the USB drive is not connected. The automation script enables it temporarily for each run and disables it again immediately after. Do not enable the task permanently unless you ensure the USB pool is always available.

### Cron Interval vs. Backup Frequency
The cron job runs every 10 minutes to detect the drive, but the actual backup only runs **once per 24 hours** (enforced by a lock file). If you connect the drive, let it run, and reconnect it within 24 hours, no second backup will be triggered. This is intentional.

### Log File is Not Persistent Across Reboots
By default, the log is written to `/var/log/usb-backup.log`, which does not survive a TrueNAS reboot. To keep logs permanently, change the `LOGFILE` path in the script to a location on your ZPool, e.g. `/mnt/zdata/scripts/usb-backup.log`.

---

## Contents of This Folder

| File | Description |
|---|---|
| `truenas-usb-backup.md` | Step-by-step setup guide: pool creation, snapshot task, replication task, automation script, cron job, and tests |
| `truenas-zfs-snapshots-explained.md` | Explanation of ZFS snapshots and replication: how space is consumed, incremental replication, backup drive growth, and capacity planning |

---

*Last updated: 2026-06-28 | TrueNAS Scale 25.10.4 Goldeye*
