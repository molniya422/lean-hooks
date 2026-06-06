#!/usr/bin/env bash
# SkillOpt + MultiAgentOpt feedback counter — Stop hook
# Parses feedback.md files to keep meta.json in sync.
# The AI still judges what to record (per CLAUDE.md).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

META="$HARNESS_ROOT/skill-feedback/meta.json"
FEEDBACK="$HARNESS_ROOT/skill-feedback/feedback.md"
MULTIAGENT_META="$HARNESS_ROOT/multiagent-feedback/meta.json"
MULTIAGENT_FEEDBACK="$HARNESS_ROOT/multiagent-feedback/feedback.md"
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

# Count skill-feedback entries
misses=0
fps=0
if [ -f "$FEEDBACK" ]; then
  misses=$(grep -c '^### .*[Mm]iss' "$FEEDBACK" 2>/dev/null || echo 0)
  fps=$(grep -c '^### .*[Ff]alse [Pp]ositive' "$FEEDBACK" 2>/dev/null || echo 0)
fi
entries=$((misses + fps))

# Count multiagent-feedback entries
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

# Stderr alerts
if [ "$entries" -ge "$THRESHOLD" ]; then
  cat >&2 <<EOF
[SkillOpt] THRESHOLD — $entries/$THRESHOLD signals. Review CLAUDE.md trigger rules.
EOF
fi

if [ "$ma_entries" -ge "$MA_THRESHOLD" ]; then
  cat >&2 <<EOF
[MultiAgentOpt] THRESHOLD — $ma_entries/$MA_THRESHOLD signals. Review multiagent-detect scoring rules.
EOF
fi

# Stdout log
echo "[Harness] Session #$sessions. SkillOpt: $entries/$THRESHOLD (m=$misses fp=$fps). MAOpt: $ma_entries/$MA_THRESHOLD (m=$ma_misses fp=$ma_fps)."
echo '{"continue":true,"suppressOutput":true}'
