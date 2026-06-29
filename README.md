# Collection of Scripts and Tips for Homelab Servers

This repo includes handy scripts and configs for software commonly used in homelab setups.  

> ⚙️ **Note:**  
> This repository assumes you already have a working homelab or server environment.  
> Some basic experience with the Linux shell is required — you’ll likely need to edit files directly in the shell and make changes under `/etc` or to system services using `systemctl`.

---

## Wake-on-LAN (and Shutdown) for VMs and LXC Containers in Proxmox

These scripts let you wake up Proxmox VMs and LXC containers using Wake-on-LAN (WoL) packets.  
The same trick is used for shutdown — by sending WoL packets on a different port.  
For more details see the [proxmox-wol](proxmox-wol/) folder.

---

## AppStart Utility Script for TrueNAS SCALE

This helper script (`appstart.sh`) automates running maintenance or scan jobs inside TrueNAS SCALE app containers.  
It ensures a specified app is **running** before executing a user-defined script inside its container and can optionally **stop the app afterward** if it was not originally running.

Typical use cases include automating antivirus scans (see below e.g., ClamAV) or other scheduled maintenance tasks through cron jobs.

For more details see the [cronscript](cronscript) folder


---

## Backup to USB Drive on TrueNAS SCALE

This guide describes how to set up an automated offsite-style backup from a TrueNAS SCALE pool to an external USB hard drive using ZFS snapshots and replication:

* Creating a ZPool on the USB drive
* Setting up a daily snapshot task on the source pool
* Configuring a replication task to mirror snapshots to the USB drive
* Running the initial replication and verifying success
* Testing the full export / disconnect / reconnect / import cycle
* Automating the entire process with a shell script and cron job — the script detects when the USB drive is powered on, imports the pool, runs the replication, and exports the pool again; a 24-hour lock prevents repeated runs if the drive stays connected
* An explanation of how ZFS snapshots and incremental replication work, including space usage over time and how file additions, modifications, and deletions affect backup drive growth

For more details see the [truenas-usb-backup](truenas-usb-backup/) folder.

---

## ClamAV on TrueNAS

Here the use of ClamAV within TrueNAS is described:
* Installing the ClamAV app  
* Script for starting ClamAV  
* CRON jobs in TrueNAS to start the app together with ClamAV on a regular basis  
* Advanced configuration with app-per-directory scan, parallelism, etc.  

For more details see the [truenas-clamav](truenas-clamav/) folder.