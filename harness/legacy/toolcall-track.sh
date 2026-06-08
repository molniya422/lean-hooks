#!/usr/bin/env bash
# ToolCallOpt — Stop hook
# Tool call pattern tracker for the training closed loop.
# Analyzes the session's tool call patterns (self-reported by AI via
# post-task reflection, or parsed from transcript_path if available).
#
# Three feedback loops in lean-hooks:
#   SkillOpt       — skill trigger accuracy
#   MultiAgentOpt  — multi-agent dispatch accuracy
#   ToolCallOpt    — tool call pattern quality
#
# ToolCallOpt tracks patterns like:
#   Positive (reinforce):  Read-before-Edit, test-after-change
#   Negative (correct):    Blind Edit, Retry Loop, Tiny Steps
#
# Like SkillOpt/MultiAgentOpt, this script maintains meta.json counters
# and injects threshold alerts. The AI decides what to record.
#
# Usage:
#   export HARNESS_ROOT=~/.claude
#   bash toolcall-track.sh
set -euo pipefail

export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

# Source env for Python detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/env.sh" ]; then
  source "$SCRIPT_DIR/env.sh"
fi

# Default paths (overridable via env)
HARNESS_ROOT="${HARNESS_ROOT:-$SCRIPT_DIR/..}"
TOOLCALL_DIR="${TOOLCALL_DIR:-$HARNESS_ROOT/toolcall-feedback}"
META="$TOOLCALL_DIR/meta.json"
FEEDBACK="$TOOLCALL_DIR/feedback.md"
THRESHOLD="${TOOLCALL_THRESHOLD:-3}"
PY="${PY:-python3}"

# Ensure toolcall-feedback directory exists
mkdir -p "$TOOLCALL_DIR"

# Read current meta
sessions=0
observations=0
last_optimized="unknown"
if [ -f "$META" ]; then
  sessions=$("$PY" -c "import json; d=json.load(open(r'$META',encoding='utf-8')); print(d.get('sessions',0))" 2>/dev/null || echo 0)
  observations=$("$PY" -c "import json; d=json.load(open(r'$META',encoding='utf-8')); print(d.get('observations',0))" 2>/dev/null || echo 0)
  last_optimized=$("$PY" -c "import json; d=json.load(open(r'$META',encoding='utf-8')); print(d.get('last_optimized','unknown'))" 2>/dev/null || echo unknown)
fi

sessions=$((sessions + 1))
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Count actual observation entries in feedback.md
if [ -f "$FEEDBACK" ]; then
  obs_count=$(grep -cE '^### (Positive|Negative)' "$FEEDBACK" 2>/dev/null || echo 0)
else
  obs_count=0
  # Create initial feedback.md
  cat > "$FEEDBACK" <<- 'FEOF'
# ToolCallOpt Feedback

Record observations about tool call patterns here.
Use headings to categorize:

### Positive <pattern>
What worked well and should be reinforced.

### Negative <pattern>
What should be corrected in future sessions.

Format:
```
### Positive Read-before-Edit
Understood file structure before modifying — efficient.

### Negative Retry-Loop
Ran `npm test` 3 times without fixing the underlying issue first.
```

FEOF
fi

# Update meta.json
"$PY" -c "
import json
d = {
  'sessions': $sessions,
  'observations': $obs_count,
  'total_feedback_entries': $obs_count,
  'threshold': $THRESHOLD,
  'last_optimized': '$last_optimized',
  'last_session': '$now'
}
json.dump(d, open(r'$META', 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
"

# Emit threshold alert via stderr (visible in AI context)
if [ "$obs_count" -ge "$THRESHOLD" ]; then
  cat >&2 <<- EOM
[ToolCallOpt] THRESHOLD REACHED — $obs_count/$THRESHOLD observations accumulated.
Action required: review tool call patterns in toolcall-feedback/feedback.md.
Common patterns to optimize:
  - Blind Edit (Edit without Read) → Always Read before Edit
  - Retry Loop (same cmd 3+ times) → Investigate root cause first
  - Tiny Steps (many small Edits) → Batch related changes
EOM

  # Inject ToolCallOpt reminder via additionalContext
  cat >&2 <<- 'EOM'
[ToolCallOpt] Session-end reflection:
  Review the tool calls made this session:
  - Did you Read before Edit?
  - Were there unnecessary retries?
  - Could changes be batched more efficiently?
  Record observations to toolcall-feedback/feedback.md if patterns are notable.
EOM
fi

# Inject session-end tool call reflection prompt
cat >&2 <<- 'EOM'
[ToolCallOpt] 本轮工具调用反思:
  - 盲改: 是否在没有 Read 的情况下 Edit/Write 文件？
  - 重试: 是否有重复执行同一命令 3+ 次？
  - 效率: 工具调用是否有优化空间？
  => 记录有价值的观察到 toolcall-feedback/feedback.md（正/负样本均可）
EOM

echo "[Harness] ToolCallOpt: session #$sessions, $obs_count observations (threshold: $THRESHOLD)."
echo '{"continue":true,"suppressOutput":true}'
