#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

"$SCRIPT_DIR/rn_setup.sh"
"$SCRIPT_DIR/rn_app.sh"
