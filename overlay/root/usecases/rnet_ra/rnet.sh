#!/usr/bin/env bash
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RX_FILE="$SCRIPT_DIR/packet.txt"
IVSHMEM_DEV="/sys/bus/pci/devices/0000:00:03.0/resource2"

cd "$SCRIPT_DIR"
/root/rw_ivshmem -f "$IVSHMEM_DEV" --prefault configs/rnet.json
cat configs/rnet.json > /dev/rsi_policy_json
/root/rw_ivshmem -f "$IVSHMEM_DEV" -C "$RX_FILE"
python3 "$SCRIPT_DIR/send_pkt.py" "$RX_FILE"
