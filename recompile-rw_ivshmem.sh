#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${1:-$DIR/overlay/root/rw_ivshmem.c}"
OUT="${2:-$DIR/overlay/root/rw_ivshmem}"
CC="${CC:-aarch64-linux-gnu-gcc}"

if [[ ! -f "$SRC" ]]; then
  echo "ERROR: source not found: $SRC" >&2
  exit 1
fi

if ! command -v "$CC" >/dev/null 2>&1; then
  echo "ERROR: compiler not found: $CC" >&2
  echo "Install an ARM64 cross-compiler (example: aarch64-linux-gnu-gcc)." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"
"$CC" -O2 -Wall -o "$OUT" "$SRC"
chmod 0755 "$OUT"

if ! file "$OUT" | grep -Eqi 'ARM aarch64|ARM64|aarch64'; then
  echo "ERROR: output is not an AArch64 binary: $OUT" >&2
  exit 1
fi

echo "[ok] built $OUT from $SRC using $CC"
