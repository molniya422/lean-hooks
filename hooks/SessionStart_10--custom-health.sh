#!/usr/bin/env bash
# Example plugin: custom health check
# File: hooks/SessionStart_10--custom-health.sh
# Priority 10 (runs before default hooks at priority 100)
#
# Plugin format: <Event>[_<Priority>]--<Name>.sh
# Priority defaults to 100 if omitted.

echo "[custom-health] Running custom health checks..."
# Add your custom checks here
echo "[custom-health] All custom checks passed."