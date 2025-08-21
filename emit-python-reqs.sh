#!/bin/sh
set -eu
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REQ="$DIR/requirements.txt"
OUT="${ROOTDIR}/tmp/py-reqs.txt"
mkdir -p "$(dirname "$OUT")"
cp -v "$REQ" "$OUT"
echo "[emit-python-reqs] wrote $(wc -l < "$OUT") lines to $OUT"
