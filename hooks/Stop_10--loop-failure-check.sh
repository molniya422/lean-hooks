#!/usr/bin/env bash
# Loop failure detection — Stop hook plugin (priority 10)
# Runs lightweight failure check at session end and updates failure-report.json.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../harness/env.sh"

if [ ! -d "$LOOP_ENG_DIR" ]; then
    echo '{"continue":true,"suppressOutput":true}'
    exit 0
fi

# Run lightweight session-level failure check (non-blocking)
"$PY" "$HARNESS_DIR/loop-failure-detector.py" check --session --json 2>/dev/null || true

echo '{"continue":true,"suppressOutput":true}'
