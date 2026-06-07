#!/usr/bin/env bash
# SkillOpt session + feedback counter — Stop hook
# Heavy mode v2: parses feedback.md to keep meta.json in sync.
# The AI still does the judgment of what to record (per CLAUDE.md §6.2).
# This script only maintains the counter and emits threshold alerts.
# Uses Anaconda python explicitly — MINGW64's `python3` (WindowsApps stub)
# exits 49 and breaks hooks silently.
set -euo pipefail

export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

PY="D:/jiqixuexi/anaconda/python.exe"
META="D:/claude-ecosystem/config/skill-feedback/meta.json"
FEEDBACK="D:/claude-ecosystem/config/skill-feedback/feedback.md"
MULTIAGENT_META="D:/claude-ecosystem/config/multiagent-feedback/meta.json"
MULTIAGENT_FEEDBACK="D:/claude-ecosystem/config/multiagent-feedback/feedback.md"
THRESHOLD=5
MA_THRESHOLD=3

# Read current state
if [ -f "$META" ]; then
  sessions=$("$PY" -c "import json; d=json.load(open(r'$META',encoding='utf-8')); print(d.get('sessions',0))" 2>/dev/null || echo 0)
  last_optimized=$("$PY" -c "import json; d=json.load(open(r'$META',encoding='utf-8')); print(d.get('last_optimized','unknown'))" 2>/dev/null || echo unknown)
else
  sessions=0
  last_optimized=unknown
fi

# Count actual entries in skill-feedback.md (single source of truth)
misses=0
fps=0
if [ -f "$FEEDBACK" ]; then
  misses=$(grep -c '^### 漏报' "$FEEDBACK" 2>/dev/null || echo 0)
  fps=$(grep -c '^### 误报' "$FEEDBACK" 2>/dev/null || echo 0)
fi
entries=$((misses + fps))

# Count actual entries in multiagent-feedback.md
ma_misses=0
ma_fps=0
if [ -f "$MULTIAGENT_FEEDBACK" ]; then
  ma_misses=$(grep -c '^### Miss' "$MULTIAGENT_FEEDBACK" 2>/dev/null || echo 0)
  ma_fps=$(grep -c '^### False Positive' "$MULTIAGENT_FEEDBACK" 2>/dev/null || echo 0)
fi
ma_entries=$((ma_misses + ma_fps))

sessions=$((sessions + 1))
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Update skill meta
"$PY" -c "
import json
d = {
  'sessions': $sessions,
  'misses': $misses,
  'false_positives': $fps,
  'total_feedback_entries': $entries,
  'threshold': $THRESHOLD,
  'last_optimized': '$last_optimized',
  'last_session': '$now'
}
json.dump(d, open(r'$META', 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
"

# Update multiagent meta
"$PY" -c "
import json
d = {
  'sessions': $sessions,
  'misses': $ma_misses,
  'false_positives': $ma_fps,
  'total_feedback_entries': $ma_entries,
  'threshold': $MA_THRESHOLD,
  'last_optimized': 'unknown',
  'last_session': '$now'
}
json.dump(d, open(r'$MULTIAGENT_META', 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
"

# Stderr output goes to AI context (not user-visible)
if [ "$entries" -ge "$THRESHOLD" ]; then
  cat >&2 <<EOF
[SkillOpt] THRESHOLD REACHED — $entries/$THRESHOLD signals accumulated.
Action required: review CLAUDE.md Section 6 trigger rules, then reset meta.json threshold check.
EOF
fi

if [ "$ma_entries" -ge "$MA_THRESHOLD" ]; then
  cat >&2 <<EOF
[MultiAgentOpt] THRESHOLD REACHED — $ma_entries/$MA_THRESHOLD signals accumulated.
Action required: review multiagent-detect scoring rules in config/harness/multiagent-detect.sh.
EOF
fi

# Stdout: silent to user, but echo for log
echo "[Harness] Session #$sessions logged. SkillOpt: $entries/$THRESHOLD (m=$misses fp=$fps). MultiAgentOpt: $ma_entries/$MA_THRESHOLD (m=$ma_misses fp=$ma_fps)."

# Hook protocol output
echo '{"continue":true,"suppressOutput":true}'
