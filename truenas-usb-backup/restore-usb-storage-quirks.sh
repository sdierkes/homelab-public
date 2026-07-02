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