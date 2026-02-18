#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="${1:-$DIR/model.gguf}"
INPUT_FILE="${2:-$DIR/ri_in.txt}"
OUTPUT_FILE="${3:-$DIR/ri_out_raw.txt}"

if [[ ! -x "$DIR/llama-cli" ]]; then
  echo "RI: missing executable $DIR/llama-cli" >&2
  exit 1
fi

if [[ ! -f "$MODEL" ]]; then
  echo "RI: missing model $MODEL" >&2
  exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "RI: missing input file $INPUT_FILE" >&2
  exit 1
fi

QUERY="$(cat "$INPUT_FILE")"
nice -n -20 "$DIR/llama-cli" \
  -m "$MODEL" \
  -p "$QUERY" \
  -n 80 \
  --no-display-prompt \
  --temp 0.3 > "$OUTPUT_FILE"

echo "RI: inference output written to $OUTPUT_FILE"
