#!/usr/bin/env bash
# Shared environment detection for all harness scripts.
# Source this at the top of every harness script:
#   source "$(dirname "$0")/env.sh"
# Users can override:
#   HARNESS_PYTHON — path to Python interpreter (default: auto-detect)
#   HARNESS_ROOT  — root of harness config directory (default: parent of harness/)

set -euo pipefail

# --- Python detection ---
if [ -n "${HARNESS_PYTHON:-}" ]; then
    PY="$HARNESS_PYTHON"
elif command -v python3 &>/dev/null; then
    PY="python3"
elif command -v python &>/dev/null; then
    PY="python"
else
    echo "[harness] ERROR: Python not found. Set HARNESS_PYTHON=/path/to/python" >&2
    exit 1
fi

# --- Harness root detection ---
if [ -n "${HARNESS_ROOT:-}" ]; then
    HARNESS_ROOT="${HARNESS_ROOT%/}"
else
    # Default: the directory containing the harness/ scripts directory
    HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

# --- Common paths ---
MEMORY_DIR="$HARNESS_ROOT/projects/\${PROJECT_NAME:-default}/memory"
FEEDBACK_DIR="$HARNESS_ROOT/skill-feedback"
MULTIAGENT_DIR="$HARNESS_ROOT/multiagent-feedback"
MEM_DB="$HARNESS_ROOT/data/claude-mem.db"
