#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CFG="$SCRIPT_DIR/configs/rg.json"
PREF_SHM1="$SCRIPT_DIR/configs/prefault_shm1.json"
PREF_SHM2="$SCRIPT_DIR/configs/prefault_shm2.json"

# shm1 on 00:03.0/resource2, shm2 on 00:04.0/resource2
DEV_TX="/sys/bus/pci/devices/0000:00:03.0/resource2"
DEV_RX="/sys/bus/pci/devices/0000:00:04.0/resource2"

cd "$SCRIPT_DIR"

/root/rw_ivshmem -f "$DEV_TX" --prefault "$PREF_SHM1"
/root/rw_ivshmem -f "$DEV_RX" --prefault "$PREF_SHM2"
cat "$CFG" > /dev/rsi_policy_json

echo "RG setup complete"
