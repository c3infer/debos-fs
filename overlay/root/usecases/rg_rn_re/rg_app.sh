#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TX_FILE="$SCRIPT_DIR/tiny.mp4"
RX_FILE="$SCRIPT_DIR/re_to_rg_out.mp4"

DEV_TX="/sys/bus/pci/devices/0000:00:03.0/resource2"
DEV_RX="/sys/bus/pci/devices/0000:00:04.0/resource2"

cd "$SCRIPT_DIR"

if [[ ! -f "$TX_FILE" ]]; then
  echo "RG: missing $TX_FILE. Build it with: ./make_tiny.sh" >&2
  exit 1
fi

"$SCRIPT_DIR/stream_send.sh" "$DEV_TX" "$TX_FILE" 262144 "RG-TX"
"$SCRIPT_DIR/stream_recv.sh" "$DEV_RX" "$RX_FILE" 1 "RG-RX"
