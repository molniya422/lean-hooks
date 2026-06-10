#!/usr/bin/env bash
# lean-hooks plugin loader
#
# Scans $CONFIG_DIR/hooks/*.sh for auto-registered hook plugins.
# Each plugin declares metadata via filename convention:
#   <event>--<name>.sh   (e.g. SessionStart--my-check.sh)
#   <event>_<priority>--<name>.sh  (e.g. SessionStart_50--my-check.sh)
#
# Priority: lower number runs first (default: 100).
# Events: SessionStart, UserPromptSubmit, Stop
#
# Usage:
#   source "$HARNESS_DIR/plugin-loader.sh"
#   run_plugins "SessionStart"
#   run_plugins "UserPromptSubmit"
set -euo pipefail

# Default plugin directory
PLUGIN_DIR="${PLUGIN_DIR:-$CONFIG_DIR/hooks}"

# Run all plugins for a given event
run_plugins() {
    local event="$1"
    local plugin_dir="${PLUGIN_DIR}"

    if [ ! -d "$plugin_dir" ]; then
        return 0
    fi

    # Find plugins: format <event>[_<priority>]--<name>.sh
    # Use sort -t_ -k2 -n for priority ordering
    local plugin_files=()
    while IFS= read -r -d '' f; do
        plugin_files+=("$f")
    done < <(find "$plugin_dir" -maxdepth 1 -name "${event}*.sh" -type f -print0 2>/dev/null || true)

    if [ ${#plugin_files[@]} -eq 0 ]; then
        return 0
    fi

    # Sort by priority embedded in filename
    # Priority is the number after first underscore before --
    local sorted=()
    for f in "${plugin_files[@]}"; do
        local base
        base=$(basename "$f")
        # Extract priority: SessionStart_50--name.sh -> 50
        local prio=100
        if [[ "$base" =~ ^[A-Za-z]+_([0-9]+)-- ]]; then
            prio="${BASH_REMATCH[1]}"
        fi
        sorted+=("$prio:$f")
    done

    # Sort by priority (simple bubble since arrays are small)
    local i j temp
    for ((i = 0; i < ${#sorted[@]}; i++)); do
        for ((j = i + 1; j < ${#sorted[@]}; j++)); do
            local prio_i="${sorted[i]%%:*}"
            local prio_j="${sorted[j]%%:*}"
            if [ "${prio_i:-100}" -gt "${prio_j:-100}" ]; then
                temp="${sorted[i]}"
                sorted[i]="${sorted[j]}"
                sorted[j]="$temp"
            fi
        done
    done

    for entry in "${sorted[@]}"; do
        local plugin_file="${entry#*:}"
        local plugin_name
        plugin_name=$(basename "$plugin_file")

        # Check if disabled
        if [ -n "${DISABLED_HOOKS:-}" ]; then
            local IFS=','
            local found=false
            for d in $DISABLED_HOOKS; do
                local d_trim
                d_trim=$(echo "$d" | xargs)
                # Match by plugin name (strip event prefix and priority)
                local plugin_key="${plugin_name#*--}"
                plugin_key="${plugin_key%.sh}"
                if [ "$d_trim" = "$plugin_key" ] || [ "$d_trim" = "$plugin_name" ]; then
                    found=true
                    break
                fi
            done
            if $found; then
                continue
            fi
        fi

        if [ -x "$plugin_file" ] || [ -f "$plugin_file" ]; then
            # Source or execute based on convention
            # Executable scripts are run, non-executable are sourced
            if [ -x "$plugin_file" ]; then
                # Run with stdin passthrough
                bash "$plugin_file" 2>&1 || {
                    echo "[lean-hooks] WARNING: plugin $plugin_name failed (exit $?) — continuing" >&2
                }
            else
                # Source it (for hooks that set variables)
                source "$plugin_file" 2>/dev/null || {
                    echo "[lean-hooks] WARNING: plugin $plugin_name failed to source — continuing" >&2
                }
            fi
        fi
    done
}

# List available plugins with metadata
list_plugins() {
    local plugin_dir="${PLUGIN_DIR}"

    if [ ! -d "$plugin_dir" ]; then
        echo "No plugin directory found at $plugin_dir"
        return 0
    fi

    echo "Available plugins:"
    echo "------------------"
    while IFS= read -r -d '' f; do
        local base prio event name
        base=$(basename "$f")
        prio="100"
        if [[ "$base" =~ ^([A-Za-z]+)_([0-9]+)--(.+)\.sh$ ]]; then
            event="${BASH_REMATCH[1]}"
            prio="${BASH_REMATCH[2]}"
            name="${BASH_REMATCH[3]}"
        elif [[ "$base" =~ ^([A-Za-z]+)--(.+)\.sh$ ]]; then
            event="${BASH_REMATCH[1]}"
            name="${BASH_REMATCH[2]}"
        else
            name="$base"
            event="?"
        fi
        local size
        size=$(wc -c < "$f" 2>/dev/null || echo "?")
        printf "  %-15s priority=%-3s size=%-6s %s\n" "[$event]" "$prio" "$size" "$name"
    done < <(find "$plugin_dir" -maxdepth 1 -name "*.sh" -type f -print0 2>/dev/null || true)
}

# Handle CLI
if [ "${1:-}" = "list" ]; then
    list_plugins
elif [ "${1:-}" = "run" ] && [ -n "${2:-}" ]; then
    run_plugins "$2"
fi