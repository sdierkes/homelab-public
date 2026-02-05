# Proxmox Wake/Shutdown-on-LAN for Containers

see also: https://medium.com/@saschadierkes/homelab-proxmox-wol-start-stop-containers-remotely-bb6a07ad5ce1

In my homelab, I have some containers that I don’t want running all the time. Since I didn’t want to log in every time just to start or stop them — and I wasn’t looking for a more complex API-based solution — I went for a simpler approach: using a WOL (Wake-on-LAN) service running directly on Proxmox to handle it for me.

With this setup, I can easily start or stop containers from my phone or tablet using any Wake-on-LAN app.

The scripts use regular WOL packets, but the **action depends on the port** they’re sent to. Depending on the port, the same packet will either **wake up** or **shut down** a container — a little twist on the original idea of WOL. 😄

---

## Prerequisites

The scripts use a few tools that might not be installed by default, so install them first:

```bash
apt install parallel xxd
```

- **parallel** is used to start listeners on multiple ports in parallel.
- **xxd** is used to handle hexadecimal input from network packets.

If you don’t have `xxd` or don’t want to install it, you can replace that part in the script with a `hexdump`-based solution.

---

## The Scripts

There are two scripts:

1. **wol-listener.sh** – listens for WOL packets on specific ports and **starts** matching VMs or LXC containers.
2. **sol-listener.sh** – listens for WOL packets on specific ports and **shuts down** matching VMs or LXC containers.

Both share the same base logic for receiving WOL packets — the only difference is the action triggered.

Below is the explanation for `wol-listener.sh` in detail.

---

## wol-listener.sh

The script starts with the standard safe-scripting boilerplate:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
re='^[0-9]+$'
```

### Logging

A simple log function is used to write messages to syslog:

```bash
log() {
  local msg
  msg="$(date '+%F %T') [$$] $*"
  logger -p user.info -t wol-listener "$msg"
}
```

You can view the logs with:

```bash
journalctl -f -t wol-listener
```

This shows all syslog entries tagged with `wol-listener`, which is the tag defined in the `log()` function.  
The __sol-listener.sh__ script uses another tag, you can change this tag if you’d like both scripts to share the same one.

Example output:

```text
Nov 08 17:57:43 pve wol-listener[1332]: 2025-11-08 17:57:42 [1415] Received possible WOL packet on port 9 for MAC bc:24:11:09:bd:58
Nov 08 17:57:43 pve wol-listener[1332]: 2025-11-08 17:57:42 [1415] Checking QEMU VMs for MAC bc:24:11:09:bd:58...
Nov 08 17:57:45 pve wol-listener[1332]: 2025-11-08 17:57:44 [1415] Checking LXC containers for MAC bc:24:11:09:bd:58...
Nov 08 17:57:46 pve wol-listener[1332]: 2025-11-08 17:57:46 [1415]   Match in CTID 8000 (status: stopped)
Nov 08 17:57:46 pve wol-listener[1332]: 2025-11-08 17:57:46 [1415]   Starting CT 8000...
Nov 08 17:57:48 pve wol-listener[1332]: 2025-11-08 17:57:48 [1415] Listening for packets on port 9...
```

### Listening for packets

The main part of the script is the `listen_port()` function, which runs in an endless loop so it can keep processing new WOL packets:

```bash
listen_port() {
  port=$1
  while true; do
    log "Listening for packets on port $port..."
    echo "\n" | nc -knlu -p "$port" | \
    stdbuf -o0 xxd -c 6 -p | \
    stdbuf -o0 uniq | \
    stdbuf -o0 grep -v 'ffffffffffff' | \
    while read; do
      [[ -z "${REPLY}" ]] && continue
      macWOL="${REPLY:0:2}:${REPLY:2:2}:${REPLY:4:2}:${REPLY:6:2}:${REPLY:8:2}:${REPLY:10:2}"
      macWOL=$(echo "$macWOL" | tr '[:upper:]' '[:lower:]')

      # ... VM and LXC checks here ...
    done
  done
}
```

- `read` stores each input line in the variable `REPLY`.
- `[[ -z "${REPLY}" ]] && continue` skips empty lines.
- The next line extracts and formats the MAC address from the raw hex input.

### Checking and starting VMs

Once a MAC address is parsed, the script checks whether any **QEMU VM** is configured with that MAC:

```bash
/usr/sbin/qm list | awk 'NR>1 {print $1}' | while read -r vid; do
  if /usr/sbin/qm config "$vid" | grep -Ei '^net[0-9]+:' | tr '[:upper:]' '[:lower:]' | grep -q "$macWOL"; then
    status=$(/usr/sbin/qm status "$vid" | awk '{print $2}')
    log "  Match in VMID $vid (status: $status)"
    if [[ "$status" == "running" ]]; then
      log "  VMID $vid already running — skip"
    else
      log "  Starting VMID $vid..."
      /usr/sbin/qm start "$vid"
    fi
  fi
done
```

The LXC section works the same way, but uses `pct`:

```bash
/usr/sbin/pct list | awk 'NR>1 {print $1}' | while read -r ctid; do
  if /usr/sbin/pct config "$ctid" | grep -Ei '^net[0-9]+:' | tr '[:upper:]' '[:lower:]' | grep -q "$macWOL"; then
    cstatus=$(/usr/sbin/pct status "$ctid" | awk '{print $2}')
    log "  Match in CTID $ctid (status: $cstatus)"
    if [[ "$cstatus" == "running" ]]; then
      log "  CT $ctid already running — skip"
    else
      log "  Starting CT $ctid..."
      /usr/sbin/pct start "$ctid"
    fi
  fi
done
```

### Running on multiple ports

At the end of the script, the functions are exported and GNU `parallel` is used to start one listener per port:

```bash
export -f listen_port
export -f log

parallel -j0 --linebuffer --env listen_port --env log \
  'stdbuf -oL -eL bash -c "listen_port \$1"' _ ::: 6 9
```

This allows the script to listen on multiple ports (here `6` and `9`) to support WOL apps that use fixed ports.

---

## sol-listener.sh

This script is almost the same as `wol-listener.sh`, but instead of *starting* a VM or container when a matching MAC is found, it does a **graceful shutdown**:

- for VMs: `qm shutdown <vmid>`
- for containers: `pct shutdown <ctid>`

You can bind this to different ports (for example 10 and 12) and then use your WOL app to “wake” on those ports to **shut down** instead of **start**.

---

## Running on Boot (systemd)

To make these listeners run automatically on Proxmox at boot, create a systemd service for each script.

### 1. Copy scripts

Put your scripts somewhere persistent and executable, for example:

```bash
sudo mkdir -p /usr/local/bin
sudo cp wol-listener.sh /usr/local/bin/
sudo cp sol-listener.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/wol-listener.sh /usr/local/bin/sol-listener.sh
```

### 2. Create systemd units

#### `/etc/systemd/system/wol-listener.service`

```ini
[Unit]
Description=Proxmox Wake-on-LAN listener (start VMs/LXCs)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wol-listener.sh
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal
SyslogIdentifier=wol-listener

[Install]
WantedBy=multi-user.target
```

#### `/etc/systemd/system/sol-listener.service`

```ini
[Unit]
Description=Proxmox Shutdown-on-LAN listener (stop VMs/LXCs)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/sol-listener.sh
Restart=always
RestartSec=5
User=root
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sol-listener

[Install]
WantedBy=multi-user.target
```

### 3. Enable and start

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now wol-listener.service
sudo systemctl enable --now sol-listener.service
```

### 4. Check logs

```bash
sudo journalctl -u wol-listener -f
sudo journalctl -u sol-listener -f
```

## Firewall

To make the scrioty reachable from the local network add firewall rules to the proxmox firewall on the host. The most open rule would be something like:

<img width="50%" height="50%" alt="image" src="https://github.com/user-attachments/assets/793bb077-c51a-4a0c-992f-6966a550b78c" />

Explanation:
- "Enable" (checkbox)
- "in"coming traffic
- and "ACCEPT" the traffic
- on protocl "udp"
- from all machines on local network "192.168.178.0/24" (adjust for your local network)
- on ports "6,9,10,12" (adjust for your needs)
- set log level to "debug" (for testing, should be redurced later to something like warning) 

---

## Notes

- Proxmox must be able to run `qm` and `pct` (so use `User=root` in the service or adjust permissions).
- Make sure the Proxmox host is allowed to receive the WOL packets (firewall, bridge, VLAN).
- You can change the ports in the script to match whatever your mobile WOL app sends.
