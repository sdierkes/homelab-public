# ZFS Snapshots & Replication — How It Works

> [!info] Overview
> This document explains how ZFS snapshots work, how they interact with replication to a backup drive, and what happens to disk space when files are added, deleted, or changed over time.

---

## What is a ZFS Snapshot?

A ZFS snapshot is a **read-only, point-in-time copy** of a dataset. It does not duplicate data — instead, it records which blocks of data existed at the moment the snapshot was taken.

```
Day 1 — Snapshot taken
┌─────────────────────────────────┐
│  zdata  (live data: 100 GB)     │
│  └── @auto-2026-06-01_02-00     │  ← snapshot: 0 MB extra space used
└─────────────────────────────────┘
```

At the moment of creation, a snapshot uses **no additional space**. Space is only consumed as the live data diverges from the snapshot over time.

---

## How Space is Consumed

ZFS uses **Copy-on-Write (CoW)**. When a file is modified or deleted, the original blocks are preserved for the snapshot. New blocks are written for the changed data.

### Example: File Modified

```
Original file: report.pdf — 500 MB

Day 1:  Snapshot @day1 taken         →  snapshot uses 0 MB extra
Day 2:  report.pdf modified (500 MB) →  old 500 MB blocks kept for @day1
                                         new 500 MB blocks written for live data
                                         extra space used: +500 MB
```

### Example: File Deleted

```
Original file: video.mp4 — 10 GB

Day 1:  Snapshot @day1 taken         →  snapshot uses 0 MB extra
Day 2:  video.mp4 deleted            →  file gone from live view
                                         but 10 GB blocks still held by @day1
                                         extra space used: +10 GB
```

> [!important]
> Deleting a file does **not** free space as long as a snapshot references that file's blocks. The space is only released when the snapshot itself is deleted.

### Example: File Added

```
Day 1:  Snapshot @day1 taken         →  snapshot uses 0 MB extra
Day 2:  new_file.zip added — 2 GB    →  new blocks written, not referenced by @day1
                                         @day1 size unchanged
                                         live data grows by +2 GB
```

New files only consume space in the live dataset — they do not affect existing snapshots.

---

## Space Usage Over Time — Concrete Example

Assume a starting dataset of **1 TB** with daily snapshots kept for **14 days**.

| Day | Event | Live Data | Snapshot Size | Total Used |
|-----|-------|-----------|---------------|------------|
| 1 | Initial state, snapshot taken | 1.00 TB | 0 MB | 1.00 TB |
| 2 | 10 GB of files modified | 1.00 TB | ~10 GB | 1.01 TB |
| 3 | 50 GB of new files added | 1.05 TB | ~10 GB | 1.06 TB |
| 4 | 20 GB of files deleted | 1.03 TB | ~30 GB | 1.06 TB |
| 7 | Normal daily changes (~5 GB/day) | 1.04 TB | ~60 GB | 1.10 TB |
| 14 | 14 days of changes accumulated | 1.05 TB | ~140 GB | 1.19 TB |
| 15 | Oldest snapshot deleted (day 1) | 1.05 TB | ~130 GB | 1.18 TB |

> [!note]
> Once the retention window is stable (oldest snapshots being deleted as new ones are created), total space usage reaches a **steady state** — it grows only as fast as your actual data changes.

---

## How Replication Works with Snapshots

Replication sends snapshots from the source pool (`zdata`) to the destination pool (`backup-usb`). It does **not** copy the live filesystem — it copies the **snapshots themselves**.

### Initial Replication (First Run)

```
Source (zdata):                     Destination (backup-usb/zdata):
┌─────────────────────┐             ┌─────────────────────┐
│  live data: 1 TB    │  ────────►  │  live data: 1 TB    │
│  @auto-2026-06-01   │  ────────►  │  @auto-2026-06-01   │
└─────────────────────┘             └─────────────────────┘

Data transferred: ~1 TB (full send)
```

The first run transfers everything. This is the longest run and requires the most bandwidth and time.

### Incremental Replication (Subsequent Runs)

After the initial run, only the **difference between two snapshots** is transferred — called an **incremental send**.

```
Day 2:
Source:                             Destination:
┌─────────────────────┐             ┌─────────────────────┐
│  @auto-2026-06-01   │             │  @auto-2026-06-01   │  (already there)
│  @auto-2026-06-02   │  ────────►  │  @auto-2026-06-02   │  (only the delta)
└─────────────────────┘             └─────────────────────┘

Data transferred: only what changed between day 1 and day 2 (~5–20 GB typical)
```

This makes subsequent replications **fast and efficient** — only changed blocks are transferred.

---

## Space on the Backup Drive

The backup drive mirrors the snapshot history of the source. Space usage follows the same rules as on the source, but there is an important consideration:

### Replication Retention Policy

The replication task is configured with `retention_policy: SOURCE`. This means:

- Snapshots on `backup-usb` are kept in sync with what exists on `zdata`
- When a snapshot expires and is deleted on `zdata`, it is also deleted on `backup-usb`
- The backup drive space usage tracks closely with the source

### Growth Scenario — Backup Drive

```
Starting point: backup-usb has 1 TB of replicated data

Week 1:   ~5 GB/day changes  →  +35 GB snapshots  →  total ~1.04 TB
Week 2:   ~5 GB/day changes  →  +35 GB snapshots  →  total ~1.08 TB
Week 4:   oldest snapshots expire, space partially freed
Steady state (14-day retention): source + ~140 GB snapshot overhead
```

### What Causes the Backup Drive to Grow Permanently

| Cause | Effect |
|-------|--------|
| New files added and never deleted | Permanent growth — data exists in all future snapshots |
| Large files modified frequently | Snapshot overhead grows — old versions are retained |
| Files deleted from live data | Space held until all snapshots referencing them expire |
| Retention period increased | More snapshots kept → more space consumed |

### What Keeps the Backup Drive Stable

| Cause | Effect |
|-------|--------|
| Stable data with few changes | Snapshot overhead stays small |
| Short retention period (e.g. 7 days) | Less history kept → less space |
| Regular snapshot expiry | Old blocks released as snapshots are deleted |

---

## Practical Space Planning

> [!tip] Rule of thumb
> Plan for **source data size + 20–30% overhead** for a 14-day retention with moderate daily changes (~1–5% of total data changed per day).

### Example: 10 TB Dataset

```
Source data:              10.0 TB
Daily change rate:        ~100 GB/day (1%)
Retention:                14 days
Snapshot overhead:        ~14 × 100 GB = ~1.4 TB

Recommended backup drive: ≥ 12 TB
```

### Example: 10 TB Dataset with Heavy Changes

```
Source data:              10.0 TB
Daily change rate:        ~500 GB/day (5%)
Retention:                14 days
Snapshot overhead:        ~14 × 500 GB = ~7 TB

Recommended backup drive: ≥ 18 TB
```

### Check Current Snapshot Space Usage on TrueNAS

```bash
# Space used by all snapshots on zdata
zfs list -o name,used,usedbysnapshots -r zdata | sort -k3 -h | tail -20

# Space used by individual snapshots
zfs list -t snapshot -o name,used,written -r zdata | tail -20

# Total snapshot overhead across entire pool
zpool list zdata
# Compare ALLOC vs SIZE — difference includes snapshot overhead
```

---

## Summary

| Concept | Key Point |
|---------|-----------|
| Snapshot at creation | Uses 0 extra space |
| File modified | Old blocks kept by snapshot — space doubles for that file until snapshot expires |
| File deleted | Space NOT freed until all referencing snapshots are deleted |
| File added | Only consumes space in live data, no snapshot impact |
| Replication (first run) | Full data transfer — time-consuming |
| Replication (subsequent) | Incremental — only changed blocks transferred |
| Backup drive growth | Mirrors source + snapshot overhead, stabilizes once retention window is full |
| Space release | Only happens when snapshots are deleted (manually or by retention policy) |

> [!warning] Common misconception
> Deleting files on the live system does **not** free space immediately if snapshots exist. The space is only reclaimed once all snapshots that reference those file blocks have been deleted. This is the most frequent cause of unexpected disk usage growth on both source and backup pools.

---

*Last updated: 2026-06-28 | TrueNAS Scale 25.10.4 Goldeye*
