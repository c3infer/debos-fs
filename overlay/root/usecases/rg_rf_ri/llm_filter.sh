#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="${1:-$DIR/model.gguf}"
INPUT_FILE="${2:-$DIR/rf_in.txt}"
OUTPUT_FILE="${3:-$DIR/rf_out.txt}"
MODE="${4:-prompt}"

if [[ ! -x "$DIR/llama-cli" ]]; then
  echo "RF: missing executable $DIR/llama-cli" >&2
  exit 1
fi

if [[ ! -f "$MODEL" ]]; then
  echo "RF: missing model $MODEL" >&2
  exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  echo "RF: missing input file $INPUT_FILE" >&2
  exit 1
fi

case "$MODE" in
  prompt)
    SYSTEM_PROMPT="Rewrite the user prompt to be safe, concise, and policy-compliant. Keep the original intent. Return only the rewritten prompt."
    ;;
  output)
    SYSTEM_PROMPT="Rewrite the assistant response to be clear, concise, and neutral. Do not add or remove facts. Return only the rewritten text."
    ;;
  *)
    echo "RF: unknown filter mode '$MODE' (use prompt|output)" >&2
    exit 1
    ;;
esac

QUERY="$SYSTEM_PROMPT: $(cat "$INPUT_FILE")"
nice -n -20 "$DIR/llama-cli" \
  -m "$MODEL" \
  -p "$QUERY" \
  -n 80 \
  --temp 0.3 > "$OUTPUT_FILE"

echo "RF: filtered ($MODE) output written to $OUTPUT_FILE"
