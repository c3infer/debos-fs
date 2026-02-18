#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPT_FILE="$SCRIPT_DIR/rg_prompt.txt"
SEED_PROMPT_FILE="$SCRIPT_DIR/prompt_example.txt"
FINAL_FILE="$SCRIPT_DIR/rg_final.txt"
DEV_LINK_RF="/sys/bus/pci/devices/0000:00:03.0/resource2"

cd "$SCRIPT_DIR"

if [[ ! -f "$SEED_PROMPT_FILE" ]]; then
  echo "RG: missing pre-generated prompt: $SEED_PROMPT_FILE" >&2
  exit 1
fi

cp -f "$SEED_PROMPT_FILE" "$PROMPT_FILE"
echo "RG: using pre-generated prompt from $SEED_PROMPT_FILE"
echo "RG: sending prompt to RF..."
/root/rw_ivshmem -f "$DEV_LINK_RF" -P "$PROMPT_FILE"

echo "RG: waiting RF to consume prompt before switching to receive..."
while true; do
  HDR_TMP="$(mktemp /tmp/rg_hdr.XXXXXX)"
  /root/rw_ivshmem -f "$DEV_LINK_RF" -R 32 | head -c 32 > "$HDR_TMP"
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

echo "RG: waiting final filtered response from RF..."
/root/rw_ivshmem -f "$DEV_LINK_RF" -C "$FINAL_FILE"

echo "RG: received final response:"
cat "$FINAL_FILE"
