#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"$SCRIPT_DIR/re_setup.sh"
"$SCRIPT_DIR/re_app.sh"
