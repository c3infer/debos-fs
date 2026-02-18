#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"$SCRIPT_DIR/rg_setup.sh"
"$SCRIPT_DIR/rg_app.sh"
