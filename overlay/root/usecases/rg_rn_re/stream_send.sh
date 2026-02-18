#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "Usage: $0 <device_path> <input_file> [ignored_chunk_bytes] [tag=TX]" >&2
  exit 2
fi

DEV="$1"
IN_FILE="$2"
CHUNK_BYTES="${3:-262144}"
TAG="${4:-TX}"

if [[ ! -r "$IN_FILE" ]]; then
  echo "$TAG: input file not readable: $IN_FILE" >&2
  exit 1
fi

FILE_SIZE="$(wc -c < "$IN_FILE")"
MAX_PAYLOAD=262112
if (( FILE_SIZE > MAX_PAYLOAD )); then
  echo "$TAG: input too large for one-slot payload ($FILE_SIZE > $MAX_PAYLOAD)" >&2
  exit 1
fi

echo "$TAG: sending '$IN_FILE' ($FILE_SIZE bytes) on $DEV using write-only raw header+payload (arg3=$CHUNK_BYTES ignored)"

python3 - "$DEV" "$IN_FILE" <<'PY'
import os
import struct
import sys
import mmap

dev = sys.argv[1]
in_file = sys.argv[2]

with open(in_file, "rb") as f:
    payload = f.read()

magic = b"IVSHFILE"

fd = os.open(dev, os.O_RDWR)
try:
    total_len = 32 + len(payload)
    mm = mmap.mmap(
        fd,
        length=total_len,
        flags=mmap.MAP_SHARED,
        prot=mmap.PROT_WRITE,
        offset=0,
    )
    try:
        # Stage 1: publish header with ready=0
        hdr_not_ready = struct.pack("<II8sQI", 0, 0, magic, len(payload), 0) + struct.pack("<I", 0)
        mm[:32] = hdr_not_ready
        # Stage 2: write payload bytes
        mm[32:32 + len(payload)] = payload
        # Stage 3: publish ready=1 as the final commit
        mm[24:28] = struct.pack("<I", 1)
        mm.flush()
    finally:
        mm.close()
finally:
    os.close(fd)
PY

echo "$TAG: send complete ($FILE_SIZE bytes)"
