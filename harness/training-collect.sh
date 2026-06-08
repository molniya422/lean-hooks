#!/usr/bin/env bash
# Training Loop Collector — Stop hook (v2.1 unified)
# Thin wrapper around training-collect.py for backward compatibility.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

exec "$PY" "$SCRIPT_DIR/training-collect.py" "$@"
