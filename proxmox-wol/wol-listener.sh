#!/usr/bin/env bash

## install to /usr/local/bin

set -Eeuo pipefail
re='^[0-9]+$'

log() {
  local msg
  msg="$(date '+%F %T') [$$] $*"
  logger -p user.info -t wol-listener "$msg"
}

listen_port() {
  port=$1
  log "Starting listener on UDP port $port..."

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
      log "Received possible WOL packet on port $port for MAC $macWOL"

      # ---- QEMU VMs ----
      if command -v /usr/sbin/qm >/dev/null 2>&1; then
        log "Checking QEMU VMs for MAC $macWOL..."
        /usr/sbin/qm list | awk 'NR>1 {print $1}' | while read -r vid; do
          [[ $vid =~ $re ]] || continue
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
      fi

      # ---- LXC containers ----
      if command -v /usr/sbin/pct >/dev/null 2>&1; then
        log "Checking LXC containers for MAC $macWOL..."
        /usr/sbin/pct list | awk 'NR>1 {print $1}' | while read -r ctid; do
          [[ $ctid =~ $re ]] || continue
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
      fi
    done
  done
}

export -f listen_port
export -f log

log "Launching parallel listeners on ports 6 and 9..."
parallel -j0 --linebuffer --env listen_port --env log \
  'stdbuf -oL -eL bash -c "listen_port \$1"' _ ::: 6 9
