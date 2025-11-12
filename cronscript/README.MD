# TrueNAS SCALE AppStart Script — Automated App Control for Cron Jobs

The `appstart.sh` utility script automates the process of safely starting and stopping TrueNAS SCALE apps for scheduled maintenance tasks.  
It is especially useful for cases such as running antivirus scans (e.g., ClamAV) or other periodic jobs like backups.

---

## Overview

When executed (manually or via cron), `appstart.sh`:

1. Checks whether a given TrueNAS app is **running**.  
2. Starts the app if it is stopped.  
3. Waits until the app reaches the **RUNNING** state.  
4. Executes a specified script inside the container.  
5. Optionally stops the app again (`--stop-after`) if it wasn’t running before.  

This ensures your scheduled jobs can safely run even when the app isn’t always active — without leaving unnecessary services running afterward.

---

## Setup Guide

I use a dedicated dataset called **`docker-mounts`** for all mounts and scripts related to apps.  
Within this dataset, I maintain a directory structure that mirrors the individual apps.

The following example assumes your pool is named `zdata`.  
Adjust dataset paths as needed for your environment.

---

### 1. Create a dedicated dataset

Create a dataset that will hold all automation scripts and related files.  
You can do this in the TrueNAS UI or via shell:

```bash
zfs create zdata/docker-mounts
```

This dataset serves as a shared mount point for maintenance scripts accessible from both the TrueNAS host and app containers.

---

### 2. Create the directory structure

Inside `docker-mounts`, set up subdirectories for your global cron scripts and per-app folders:

```bash
mkdir -p /mnt/zdata/docker-mounts/cron-scripts
mkdir -p /mnt/zdata/docker-mounts/clamav
mkdir -p /mnt/zdata/docker-mounts/<other-app-name>
```

Within `/mnt/zdata/docker-mounts/clamav`, I usually mirror some standard Linux paths.  
For the run script:

```bash
mkdir -p /mnt/zdata/docker-mounts/clamav/usr/local/bin
```

And for data and logs:

```bash
mkdir -p /mnt/zdata/docker-mounts/clamav/var/lib/clamav
mkdir -p /mnt/zdata/docker-mounts/clamav/var/log/clamav
```

**Structure overview:**

```
/mnt/zdata/docker-mounts/
│
├── cron-scripts/
│   └── appstart.sh                  ← This script
│
├── clamav/
│   ├── usr/local/bin/clamav.sh      ← Run script executed inside the container
│   ├── var/log/clamav/              ← Log folder
│   └── var/lib/clamav/              ← Database folder
│
└── <other-app-name>/
    └── <custom-script>.sh           ← Other app-specific maintenance script
```

---

### 3. Place the `appstart.sh` script

Download or copy the script into:

```
/mnt/zdata/docker-mounts/cron-scripts/
```

Make it executable:

```bash
chmod +x /mnt/zdata/docker-mounts/cron-scripts/appstart.sh
```

---

### 4. Create per-app run scripts

Each app (for example, ClamAV) should have its own maintenance or scan script inside its dedicated directory.  
For a detailed example, see [truenas-clamav](/truenas-clamav/).

---

### 5. Mount the run script directory into the app

In the TrueNAS SCALE **App Configuration** page for your app (e.g., ClamAV):

1. Open the **Storage** section.  
2. Add **Host Path Volume** mounts:  
   - For the script:  
     - **Host Path:** `/mnt/zdata/docker-mounts/clamav/usr/local/bin`  
     - **Mount Path inside Container:** `/opt/host/usr/local/bin`  
   - For the `/var` folder:  
     - **Host Path:** `/mnt/zdata/docker-mounts/clamav/var`  
     - **Mount Path inside Container:** `/opt/host/var`  
3. Save and redeploy the app.

The container can now access your run script at:

```
/opt/host/usr/local/bin/clamav.sh
```

> [!IMPORTANT]
> You may need to adjust file ownership and permissions inside the container.  
> For example, `freshclam` expects `/var/lib` to be owned by the `clamav` user and writable only by that user.  
> To fix this, log into the container (via the UI or shell) and run something like:
>
> ```bash
> chown -R clamav:clamav /opt/host/var
> chmod -R u+rwx /opt/host/var/lib
> chmod -R go-rwx /opt/host/var/lib
> ```

---

### 6. Test the setup manually

You can test the setup manually before scheduling it (using ClamAV as an example) from the TrueNAS shell:

```bash
/mnt/zdata/docker-mounts/cron-scripts/appstart.sh   clamav ix-clamav-clamav-1 /opt/host/usr/local/bin/clamav.sh clamav-cron --stop-after
```

Expected behavior:

- If the app is stopped, it will start.  
- The script `clamav.sh` will run inside the container.  
- Once finished, the app will stop again (because of `--stop-after`).  

You can check the logs in TrueNAS at:

```
/mnt/zdata/docker-mounts/clamav/var/log/clamav
```

(Depending on how your script is configured.)

---

### 7. Add a cron job in TrueNAS

Go to **System Settings → Advanced → Cron Jobs → Add** and configure (for the ClamAV example):

| Field | Value |
|-------|--------|
| **User** | root |
| **Command** | `/mnt/zdata/docker-mounts/cron-scripts/appstart.sh clamav ix-clamav-clamav-1 /opt/host/usr/local/bin/clamav.sh clamav-cron --stop-after` |
| **Schedule** | As desired |
| **Description** | Optional note or label |

Make sure the paths and parameters match your actual dataset and app/container names.
