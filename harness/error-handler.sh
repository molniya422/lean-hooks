#!/usr/bin/env bash
# lean-hooks error handler — sourced by env.sh
# Provides timeout_wrap, error_log, and safe_run for all hook scripts.
# Failures are logged to ERRORS.md without blocking main flow.
set -euo pipefail

# --- Config ---
ERRORS_FILE="${ERRORS_FILE:-$CONFIG_DIR/ERRORS.md}"
MAX_ERROR_AGE="${MAX_ERROR_AGE:-2592000}"  # 30 days in seconds

# Ensure ERRORS.md exists with header
_ensure_errors_md() {
    if [ ! -f "$ERRORS_FILE" ]; then
        cat > "$ERRORS_FILE" << 'ERRHEAD'
# lean-hooks Error Log

> Auto-generated error log. Entries older than 30 days are pruned on write.

| Timestamp | Hook | Duration | Exit Code | Error |
|-----------|------|----------|-----------|-------|
ERRHEAD
    fi
}

# Log an error to ERRORS.md, then prune old entries
error_log() {
    local hook_name="$1"
    local exit_code="$2"
    local duration="$3"
    local error_msg="${4:-unknown}"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")"

    _ensure_errors_md

    # Append error row
    printf "| %s | %s | %ss | %d | %s |\n" \
        "$timestamp" "$hook_name" "$duration" "$exit_code" "$error_msg" >> "$ERRORS_FILE"

    # Prune entries older than MAX_ERROR_AGE
    if command -v date &>/dev/null; then
        local cutoff
        cutoff=$(date -d "-${MAX_ERROR_AGE} seconds" +%s 2>/dev/null || echo 0)
        if [ "$cutoff" != "0" ]; then
            local tmp_file
            tmp_file="${ERRORS_FILE}.tmp"
            # Keep header (first 4 lines) + recent entries
            head -4 "$ERRORS_FILE" > "$tmp_file" 2>/dev/null || true
            while IFS= read -r line; do
                # Parse timestamp from first column (after leading |)
                local ts
                ts=$(echo "$line" | awk -F'|' '{print $2}' | xargs 2>/dev/null || echo "")
                if [ -n "$ts" ] && [ "$ts" != "Timestamp" ]; then
                    local ts_epoch
                    ts_epoch=$(date -d "$ts" +%s 2>/dev/null || echo 0)
                    if [ "$ts_epoch" -ge "$cutoff" ] 2>/dev/null; then
                        echo "$line" >> "$tmp_file"
                    fi
                fi
            done < <(tail -n +5 "$ERRORS_FILE" 2>/dev/null || true)
            mv "$tmp_file" "$ERRORS_FILE"
        fi
    fi
}

# Run a command with timeout, logging errors on failure.
# Usage: timeout_wrap <seconds> <hook_name> <command...>
timeout_wrap() {
    local timeout_sec="$1"
    local hook_name="$2"
    shift 2
    local start_time duration exit_code

    start_time=$(date +%s 2>/dev/null || echo 0)

    if command -v timeout &>/dev/null; then
        timeout "$timeout_sec" "$@" 2>&1 || {
            exit_code=$?
            duration=$(( $(date +%s 2>/dev/null || echo 0) - start_time ))
            if [ "$exit_code" = "124" ]; then
                error_log "$hook_name" "$exit_code" "$duration" "TIMEOUT after ${timeout_sec}s"
                echo "[lean-hooks] WARNING: $hook_name timed out after ${timeout_sec}s" >&2
            else
                error_log "$hook_name" "$exit_code" "$duration" "exit code $exit_code"
                echo "[lean-hooks] WARNING: $hook_name failed (exit $exit_code) — continuing" >&2
            fi
            return 0  # Never propagate error — non-blocking by design
        }
    else
        # No timeout command available (e.g. some Git Bash on Windows)
        "$@" 2>&1 || {
            exit_code=$?
            duration=$(( $(date +%s 2>/dev/null || echo 0) - start_time ))
            error_log "$hook_name" "$exit_code" "$duration" "exit code $exit_code"
            echo "[lean-hooks] WARNING: $hook_name failed (exit $exit_code) — continuing" >&2
            return 0
        }
    fi
}

# Run a hook safely with timeout + error logging.
# Reads config from lean-hooks.toml if available.
# Usage: safe_run <hook_name>
safe_run() {
    local hook_name="$1"
    local hook_script timeout_val

    # Resolve script path from lean-hooks.toml or use harness/<name>.sh
    if [ -f "$CONFIG_DIR/lean-hooks.toml" ]; then
        hook_script=$("$PY" -c "
import tomllib
with open('$CONFIG_DIR/lean-hooks.toml', 'rb') as f:
    cfg = tomllib.load(f)
for h in cfg.get('hook', []):
    if h.get('name') == '$hook_name':
        print(h.get('file', ''))
        break
" 2>/dev/null || echo "")
    fi
    if [ -z "$hook_script" ]; then
        hook_script="harness/${hook_name}.sh"
    fi

    # Resolve relative to CONFIG_DIR
    if [ "${hook_script#/}" = "$hook_script" ] && [ "${hook_script#~}" = "$hook_script" ]; then
        hook_script="$CONFIG_DIR/$hook_script"
    fi

    if [ ! -f "$hook_script" ]; then
        echo "[lean-hooks] WARNING: $hook_name script not found at $hook_script" >&2
        return 0
    fi

    timeout_val=$(toml_get_timeout "$hook_name" 30)
    timeout_wrap "$timeout_val" "$hook_name" bash "$hook_script"
}

# Read timeout from lean-hooks.toml for a hook
toml_get_timeout() {
    local hook_name="$1"
    local default_val="$2"
    if [ -f "$CONFIG_DIR/lean-hooks.toml" ]; then
        "$PY" -c "
import tomllib
with open('$CONFIG_DIR/lean-hooks.toml', 'rb') as f:
    cfg = tomllib.load(f)
for h in cfg.get('hook', []):
    if h.get('name') == '$hook_name':
        print(h.get('timeout', $default_val))
        break
else:
    print($default_val)
" 2>/dev/null || echo "$default_val"
    else
        echo "$default_val"
    fi
}

# Check if a hook is enabled in lean-hooks.toml
is_hook_enabled() {
    local hook_name="$1"
    # DISABLED_HOOKS env var overrides everything
    if [ -n "${DISABLED_HOOKS:-}" ]; then
        local IFS=','
        for d in $DISABLED_HOOKS; do
            if [ "$(echo "$d" | xargs)" = "$hook_name" ]; then
                return 1
            fi
        done
    fi
    # Check lean-hooks.toml
    if [ -f "$CONFIG_DIR/lean-hooks.toml" ]; then
        "$PY" -c "
import tomllib
with open('$CONFIG_DIR/lean-hooks.toml', 'rb') as f:
    cfg = tomllib.load(f)
for h in cfg.get('hook', []):
    if h.get('name') == '$hook_name':
        print('true' if h.get('enabled', True) else 'false')
        break
else:
    print('true')
" 2>/dev/null | grep -q "true" || return 1
    fi
    return 0
}