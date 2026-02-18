#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "Usage: $0 <device_path> <output_file> [poll_sleep_sec=1] [tag=RX]" >&2
  exit 2
fi

DEV="$1"
OUT_FILE="$2"
POLL_SLEEP="${3:-1}"
TAG="${4:-RX}"

TMP_DIR="$(mktemp -d /tmp/stream_recv.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

: > "$OUT_FILE"

if ! [[ "$POLL_SLEEP" =~ ^[0-9]+$ ]]; then
  POLL_SLEEP=1
fi

if (( POLL_SLEEP > 60 )); then
  # Backward compatibility with old callers passing chunk size here.
  POLL_SLEEP=1
fi

echo "$TAG: waiting for complete payload on $DEV using rw_ivshmem -R polling"

while true; do
  HDR_FILE="$TMP_DIR/hdr.bin"
  /root/rw_ivshmem -f "$DEV" -R 32 | head -c 32 > "$HDR_FILE"

  MAGIC="$(dd if="$HDR_FILE" bs=1 skip=8 count=8 2>/dev/null | tr -d '\000')"
  READY_RAW="$(od -An -t u4 -j24 -N4 "$HDR_FILE" 2>/dev/null | tr -d '[:space:]')"
  LEN_RAW="$(od -An -t u8 -j16 -N8 "$HDR_FILE" 2>/dev/null | tr -d '[:space:]')"

  READY="${READY_RAW:-0}"
  LENGTH="${LEN_RAW:-0}"
  STATUS="ready=$READY len=$LENGTH magic=${MAGIC:-<none>}"

  if [[ "$MAGIC" == "IVSHFILE" && "$READY" == "1" && "$LENGTH" != "0" ]]; then
    echo "$TAG: payload ready (len=$LENGTH), dumping..."
    /root/rw_ivshmem -f "$DEV" -D "$OUT_FILE"
    break
  fi

  echo "$TAG: waiting... $STATUS"
  sleep "$POLL_SLEEP"
done

RECV="$(wc -c < "$OUT_FILE")"
echo "$TAG: receive complete ($RECV bytes) -> $OUT_FILE"
