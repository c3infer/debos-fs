#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IN_FILE="${1:-$SCRIPT_DIR/raw.mp4}"
OUT_FILE="${2:-$SCRIPT_DIR/tiny.mp4}"
TARGET_BYTES="${3:-262112}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ERROR: ffmpeg not found in PATH" >&2
  exit 1
fi

if [[ ! -f "$IN_FILE" ]]; then
  echo "ERROR: input file not found: $IN_FILE" >&2
  exit 1
fi

TMP_OUT="$SCRIPT_DIR/.tiny_tmp.mp4"
trap 'rm -f "$TMP_OUT"' EXIT

duration_list=(2 1)
scale_list=("224:-2" "192:-2" "160:-2" "128:-2")
fps_list=(12 10 8)
crf_list=(40 42 44 46 48 50)

best_size=0
best_file=""

echo "Compressing '$IN_FILE' to <= $TARGET_BYTES bytes..."

for duration in "${duration_list[@]}"; do
  for scale in "${scale_list[@]}"; do
    for fps in "${fps_list[@]}"; do
      for crf in "${crf_list[@]}"; do
        rm -f "$TMP_OUT"
        ffmpeg -y -loglevel error -i "$IN_FILE" \
          -t "$duration" \
          -vf "scale=${scale},fps=${fps}" \
          -c:v libx264 -preset veryfast -crf "$crf" \
          -an -movflags +faststart "$TMP_OUT"

        size="$(wc -c < "$TMP_OUT")"
        echo "try: t=${duration}s scale=${scale} fps=${fps} crf=${crf} -> ${size} bytes"

        if (( best_size == 0 || size < best_size )); then
          best_size="$size"
          cp "$TMP_OUT" "$OUT_FILE"
          best_file="$OUT_FILE"
        fi

        if (( size <= TARGET_BYTES )); then
          mv "$TMP_OUT" "$OUT_FILE"
          echo "OK: wrote $OUT_FILE (${size} bytes)"
          exit 0
        fi
      done
    done
  done
done

if [[ -n "$best_file" ]]; then
  echo "WARN: could not reach ${TARGET_BYTES} bytes; best is ${best_size} bytes at $best_file" >&2
  exit 2
fi

echo "ERROR: compression failed" >&2
exit 1
