#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CFG="$SCRIPT_DIR/configs/ri.json"
PREF_SHM1="$SCRIPT_DIR/configs/prefault_shm1.json"

DEV_IN="/sys/bus/pci/devices/0000:00:03.0/resource2"

cd "$SCRIPT_DIR"

/root/rw_ivshmem -f "$DEV_IN" --prefault "$PREF_SHM1"
cat "$CFG" > /dev/rsi_policy_json

echo "RI setup complete"
