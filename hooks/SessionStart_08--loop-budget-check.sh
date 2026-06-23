#!/usr/bin/env bash
# Loop budget check — SessionStart plugin (priority 8)
# Calls loop-budget-tracker.py and injects budget warnings into AI context.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../harness/env.sh"

if [ ! -f "$LOOP_BUDGET" ]; then
    echo '{"continue":true,"suppressOutput":true}'
    exit 0
fi

budget_status=$("$PY" "$HARNESS_DIR/loop-budget-tracker.py" check --json 2>/dev/null || echo '{}')
echo "$budget_status" | "$PY" - <<'PYEOF'
import json, sys

try:
    data = json.loads(sys.stdin.read() or "{}")
except Exception:
    data = {}

if not data or "error" in data:
    print(json.dumps({"continue": True, "suppressOutput": True}))
    sys.exit(0)

pct = data.get("daily_percent", 0)
status = data.get("status", "ok")

if status == "kill" or pct >= 100:
    used = data.get("daily_tokens_used", 0)
    cap = data.get("daily_token_cap", 0)
    msg = f"[LoopBudget] KILL: Daily token cap reached ({pct}%). Loops blocked until reset. ({used:,}/{cap:,})"
    out = {"continue": True, "suppressOutput": True,
           "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": msg}}
    print(json.dumps(out))
elif status == "warning" or pct >= 80:
    used = data.get("daily_tokens_used", 0)
    cap = data.get("daily_token_cap", 0)
    msg = f"[LoopBudget] WARNING: Daily token usage at {pct}% ({used:,}/{cap:,}). Approaching cap."
    out = {"continue": True, "suppressOutput": True,
           "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": msg}}
    print(json.dumps(out))
else:
    print(json.dumps({"continue": True, "suppressOutput": True}))
PYEOF
