#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IN_FILE="$SCRIPT_DIR/rn_in.mp4"
OUT_FILE="$SCRIPT_DIR/rn_out.mp4"
THUMBS_DIR="$SCRIPT_DIR/thumbs"

DEV_IN="/sys/bus/pci/devices/0000:00:03.0/resource2"
DEV_OUT="/sys/bus/pci/devices/0000:00:04.0/resource2"

cd "$SCRIPT_DIR"

"$SCRIPT_DIR/stream_recv.sh" "$DEV_IN" "$IN_FILE" 1 "RN-RX"
python3 "$SCRIPT_DIR/analyze_video.py" "$IN_FILE" \
  --thumb-dir "$THUMBS_DIR" --no-nsfw --output-video "$OUT_FILE"
echo "RN: analysis done; output video -> $OUT_FILE"
"$SCRIPT_DIR/stream_send.sh" "$DEV_OUT" "$OUT_FILE" 262144 "RN-TX"
