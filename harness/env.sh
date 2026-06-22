#!/usr/bin/env bash
# Shared environment detection for all harness scripts.
# Source this at the top of every harness script:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/env.sh"
#
# Automatically detects claude-ecosystem vs lean-hooks layout.
#
# Users can override:
#   HARNESS_PYTHON     — path to Python interpreter
#   HARNESS_ROOT       — project root (default: auto-detected)
#   DISABLED_HOOKS     — comma-separated hooks to disable
#   CHROME_EXE         — path to Chromium executable
#   AGENT_BROWSER_BIN  — path to agent-browser binary

set -euo pipefail

# Ensure we have Python for inline scripting (needed by error-handler)
_py_detect() {
    if [ -n "${HARNESS_PYTHON:-}" ]; then
        echo "$HARNESS_PYTHON"
    elif command -v python3 &>/dev/null; then
        echo "python3"
    elif command -v python &>/dev/null; then
        echo "python"
    else
        echo ""
    fi
}

_resolve_path() {
    local base="$1" rel="$2"
    local p="$base/$rel"
    if [ -d "$p" ] || [ -f "$p" ]; then echo "$p"; else echo ""; fi
}

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

# Verify the chosen interpreter actually works (Windows Store shim fails in MINGW64)
# The Microsoft Store python3 stub opens the Store UI and exits with code 49 in
# non-interactive shells; treat that as "not executable" and fall back.
if ! "$PY" --version &>/dev/null; then
    if [ "$PY" = "python3" ] && command -v python &>/dev/null; then
        PY="python"
    elif [ "$PY" = "python" ] && command -v python3 &>/dev/null; then
        PY="python3"
    fi
    if ! "$PY" --version &>/dev/null; then
        echo "[harness] ERROR: Python '$PY' found but does not execute. Set HARNESS_PYTHON=/path/to/python" >&2
        exit 1
    fi
fi

# Extra guard: Windows Store stub exits 49 when invoked from MINGW64/Git Bash.
# Replace python3 with the working alternative now so all downstream scripts use it.
if [ "$PY" = "python3" ]; then
    _version_check=$("$PY" --version 2>&1) || _version_check=""
    if echo "$_version_check" | grep -qi "AppInstallerPythonRedirector\|Windows Store\|Microsoft Store"; then
        if command -v python &>/dev/null; then
            PY="python"
        fi
    fi
fi

# --- Project root detection ---
if [ -n "${HARNESS_ROOT:-}" ]; then
    HARNESS_ROOT="${HARNESS_ROOT%/}"
else
    SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PARENT_DIR="$(cd "$SELF_DIR/.." && pwd)"
    PARENT_NAME="$(basename "$PARENT_DIR")"
    if [ "$PARENT_NAME" = "config" ]; then
        # claude-ecosystem: harness lives under config/harness/
        # project root is 2 levels up from harness/
        HARNESS_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
    else
        # lean-hooks: harness lives directly under project root
        HARNESS_ROOT="$PARENT_DIR"
    fi
fi

# --- Export encodings ---
export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

# --- Common paths with auto-detection for claude-ecosystem layout ---
# Try config/ subdirectory first (claude-ecosystem), then root (lean-hooks)
_config_sub="$HARNESS_ROOT/config"
if [ -d "$_config_sub" ]; then
    CONFIG_DIR="$_config_sub"
else
    CONFIG_DIR="$HARNESS_ROOT"
fi

LOOP_DIR="$CONFIG_DIR/training-loop"
# Derive project memory dir: use explicit PROJECT_NAME or basename of HARNESS_ROOT with / -> --
_PROJECT_NAME="${PROJECT_NAME:-$(basename "$HARNESS_ROOT" | sed 's/\//--/g')}"
_MEMORY_DIR="$CONFIG_DIR/projects/$_PROJECT_NAME/memory"
# Backward compatibility: if old D--claude-ecosystem dir exists, prefer it
if [ ! -d "$_MEMORY_DIR" ] && [ -d "$CONFIG_DIR/projects/D--claude-ecosystem/memory" ]; then
    _MEMORY_DIR="$CONFIG_DIR/projects/D--claude-ecosystem/memory"
fi
MEMORY_DIR="$_MEMORY_DIR"
HARNESS_DIR="$CONFIG_DIR/harness"
CLAUDE_MD="$CONFIG_DIR/CLAUDE.md"
ECOSYSTEM="$HARNESS_ROOT"

# --- Normalize paths for cross-tool compatibility ---
# MINGW64 paths like /d/foo are invisible to Windows-native Python.
# Convert to D:/foo when cygpath is available. Idempotent.
_normalize_path() {
    if command -v cygpath &>/dev/null; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

HARNESS_ROOT="$(_normalize_path "$HARNESS_ROOT")"
CONFIG_DIR="$(_normalize_path "$CONFIG_DIR")"
LOOP_DIR="$(_normalize_path "$LOOP_DIR")"
MEMORY_DIR="$(_normalize_path "$MEMORY_DIR")"
HARNESS_DIR="$(_normalize_path "$HARNESS_DIR")"
CLAUDE_MD="$(_normalize_path "$CLAUDE_MD")"
ECOSYSTEM="$(_normalize_path "$ECOSYSTEM")"

# --- External dependencies (overridable via env or .env file) ---
GITIGNORED_ENV="$HARNESS_ROOT/.env"
if [ -f "$GITIGNORED_ENV" ]; then
    source "$GITIGNORED_ENV"
fi

# --- Load lean-hooks.toml configuration ---
# Priority: project-level > global (~/.claude)
_LOADED_HOOKS_CFG=""
if [ -f "$CONFIG_DIR/lean-hooks.toml" ]; then
    _LOADED_HOOKS_CFG="$CONFIG_DIR/lean-hooks.toml"
elif [ -f "$HARNESS_ROOT/lean-hooks.toml" ]; then
    _LOADED_HOOKS_CFG="$HARNESS_ROOT/lean-hooks.toml"
elif [ -f "$HOME/.claude/lean-hooks.toml" ]; then
    _LOADED_HOOKS_CFG="$HOME/.claude/lean-hooks.toml"
fi
export _LOADED_HOOKS_CFG

if [ -z "${CHROME_EXE:-}" ]; then
    CHROME_EXE="D:/Chromium/Application/chrome.exe"
fi

AGENT_BROWSER_DIR="$HARNESS_ROOT/runtime/npm/node_modules/agent-browser"
if [ -z "${AGENT_BROWSER_BIN:-}" ]; then
    AGENT_BROWSER_BIN="$AGENT_BROWSER_DIR/bin/agent-browser-win32-x64.exe"
fi

# --- Export all for child scripts ---
export PY HARNESS_ROOT CONFIG_DIR LOOP_DIR MEMORY_DIR HARNESS_DIR CLAUDE_MD ECOSYSTEM
export CHROME_EXE AGENT_BROWSER_BIN

# --- Source error handler (timeout_wrap, error_log, safe_run) ---
ERROR_HANDLER="$SCRIPT_DIR/error-handler.sh"
if [ -f "$ERROR_HANDLER" ]; then
    source "$ERROR_HANDLER"
fi
