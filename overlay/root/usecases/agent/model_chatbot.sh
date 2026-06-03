#!/usr/bin/env bash
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="${MODEL:-$SCRIPT_DIR/../rg_rf_ri/model.gguf}"
IVSHMEM_DEV="${IVSHMEM_DEV:-/sys/bus/pci/devices/0000:00:03.0/resource2}"
PREF_CFG="${PREF_CFG:-$SCRIPT_DIR/configs/prefault_shm1.json}"
POLICY_CFG="${POLICY_CFG:-$SCRIPT_DIR/configs/model.json}"
RW_IVSHMEM="${RW_IVSHMEM:-/root/rw_ivshmem}"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]
Options:
  --model|-model PATH       Path to GGUF model (default: $MODEL)
  --device|-device PATH     ivshmem resource2 path (default: $IVSHMEM_DEV)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model|-model)
      MODEL="$2"
      shift 2
      ;;
    --device|-device)
      IVSHMEM_DEV="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

cd "$SCRIPT_DIR"

if [[ ! -x "$RW_IVSHMEM" ]]; then
  echo "model_chatbot: missing executable $RW_IVSHMEM" >&2
  exit 1
fi

if [[ ! -f "$MODEL" ]]; then
  echo "model_chatbot: missing model $MODEL" >&2
  exit 1
fi

"$RW_IVSHMEM" -f "$IVSHMEM_DEV" --prefault "$PREF_CFG"
cat "$POLICY_CFG" > /dev/rsi_policy_json

python3 "$SCRIPT_DIR/model.py" \
  --model "$MODEL" \
  --device "$IVSHMEM_DEV" \
  --channel 0 \
  --infer-csv "$SCRIPT_DIR/inference_chatbot.csv" \
  --max-inferences 9
