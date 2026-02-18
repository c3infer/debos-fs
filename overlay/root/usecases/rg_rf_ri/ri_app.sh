#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL_FILE="${MODEL_FILE:-$SCRIPT_DIR/model.gguf}"

FROM_RF="$SCRIPT_DIR/ri_from_rf.txt"
RAW_OUT="$SCRIPT_DIR/ri_raw_out.txt"

DEV_LINK_RF="/sys/bus/pci/devices/0000:00:03.0/resource2"

cd "$SCRIPT_DIR"

echo "RI: waiting filtered prompt from RF..."
/root/rw_ivshmem -f "$DEV_LINK_RF" -C "$FROM_RF"

echo "RI: resetting consumed slot header on RF<->RI link..."
python3 - "$DEV_LINK_RF" <<'PY'
import mmap
import os
import struct
import sys

dev = sys.argv[1]
fd = os.open(dev, os.O_RDWR)
try:
    mm = mmap.mmap(fd, 32, flags=mmap.MAP_SHARED, prot=mmap.PROT_WRITE)
    try:
        mm[16:24] = struct.pack("<Q", 0)
        mm[24:28] = struct.pack("<I", 0)
        mm.flush()
    finally:
        mm.close()
finally:
    os.close(fd)
PY

echo "RI: running inference..."
"$SCRIPT_DIR/llm_infer.sh" "$MODEL_FILE" "$FROM_RF" "$RAW_OUT"

echo "RI: sending raw inference output back to RF..."
/root/rw_ivshmem -f "$DEV_LINK_RF" -P "$RAW_OUT"

echo "RI app complete"
