#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_FILE="${MODEL_FILE:-$SCRIPT_DIR/model.gguf}"

FROM_RG="$SCRIPT_DIR/rf_from_rg.txt"
TO_RI="$SCRIPT_DIR/rf_to_ri.txt"
FROM_RI="$SCRIPT_DIR/rf_from_ri.txt"
TO_RG="$SCRIPT_DIR/rf_to_rg.txt"

DEV_RG="/sys/bus/pci/devices/0000:00:03.0/resource2"
DEV_RI="/sys/bus/pci/devices/0000:00:04.0/resource2"

cd "$SCRIPT_DIR"

echo "RF: waiting prompt from RG..."
/root/rw_ivshmem -f "$DEV_RG" -C "$FROM_RG"

echo "RF: resetting consumed slot header on RG<->RF link..."
python3 - "$DEV_RG" <<'PY'
import mmap
import os
import struct
import sys

dev = sys.argv[1]
fd = os.open(dev, os.O_RDWR)
try:
    mm = mmap.mmap(fd, 32, flags=mmap.MAP_SHARED, prot=mmap.PROT_WRITE)
    try:
        # Keep counters and magic unchanged; clear length/ready.
        mm[16:24] = struct.pack("<Q", 0)
        mm[24:28] = struct.pack("<I", 0)
        mm.flush()
    finally:
        mm.close()
finally:
    os.close(fd)
PY

echo "RF: filtering prompt..."
"$SCRIPT_DIR/llm_filter.sh" "$MODEL_FILE" "$FROM_RG" "$TO_RI" prompt

echo "RF: sending filtered prompt to RI..."
/root/rw_ivshmem -f "$DEV_RI" -P "$TO_RI"

echo "RF: waiting RI to consume prompt before switching to receive..."
while true; do
  HDR_TMP="$(mktemp /tmp/rf_ri_hdr.XXXXXX)"
  /root/rw_ivshmem -f "$DEV_RI" -R 32 | head -c 32 > "$HDR_TMP"
  W_CNT="$(od -An -t u4 -j0 -N4 "$HDR_TMP" 2>/dev/null | tr -d '[:space:]')"
  R_CNT="$(od -An -t u4 -j4 -N4 "$HDR_TMP" 2>/dev/null | tr -d '[:space:]')"
  rm -f "$HDR_TMP"

  W_CNT="${W_CNT:-0}"
  R_CNT="${R_CNT:-0}"
  if [[ "$W_CNT" == "$R_CNT" ]]; then
    break
  fi
  sleep 1
done

echo "RF: waiting inference output from RI..."
/root/rw_ivshmem -f "$DEV_RI" -C "$FROM_RI"

echo "RF: filtering inference output..."
"$SCRIPT_DIR/llm_filter.sh" "$MODEL_FILE" "$FROM_RI" "$TO_RG" output

echo "RF: sending final filtered output to RG..."
/root/rw_ivshmem -f "$DEV_RG" -P "$TO_RG"

echo "RF app complete"
