#!/usr/bin/env bash
# Training Loop Collector — Stop hook (unified)
# Consolidates SkillOpt + MultiAgentOpt + ToolCallOpt into one structured system.
# Replaces separate skillopt-collect.sh and toolcall-track.sh.
# All three dimensions share one meta.json and one feedback.md.
set -euo pipefail

export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

PY="${HARNESS_PYTHON:-python3}"
HARNESS_ROOT="${HARNESS_ROOT:-$(dirname "$(dirname "$(readlink -f "$0")")")}"
LOOP_DIR="${LOOP_DIR:-$HARNESS_ROOT/training-loop}"
META="$LOOP_DIR/meta.json"
FEEDBACK="$LOOP_DIR/feedback.md"

# Also read legacy directories for back-compat during transition
LEGACY_SKILL_FEEDBACK="D:/claude-ecosystem/config/skill-feedback/feedback.md"
LEGACY_MULTIAGENT_FEEDBACK="D:/claude-ecosystem/config/multiagent-feedback/feedback.md"
LEGACY_TOOLCALL_FEEDBACK="D:/claude-ecosystem/config/toolcall-feedback/feedback.md"

mkdir -p "$LOOP_DIR"

# --- Read current meta ---
read_meta() {
  if [ -f "$META" ]; then
    python3 -c "import json; d=json.load(open('$META',encoding='utf-8')); print(json.dumps(d))" 2>/dev/null || \
    "$PY" -c "import json; d=json.load(open(r'$META',encoding='utf-8')); print(json.dumps(d))" 2>/dev/null || \
    echo '{"sessions":0}'
  else
    echo '{"sessions":0}'
  fi
}

# --- Count feedback entries ---
count_entries() {
  local file="$1"
  local pattern="$2"
  if [ -f "$file" ]; then
    grep -cE "$pattern" "$file" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# --- Count from unified feedback.md ---
skill_misses=$(count_entries "$FEEDBACK" "^### Miss")
skill_fps=$(count_entries "$FEEDBACK" "^### False Positive")

# Also count legacy entries during transition
legacy_skill_misses=$(count_entries "$LEGACY_SKILL_FEEDBACK" "^### 漏报")
legacy_skill_fps=$(count_entries "$LEGACY_SKILL_FEEDBACK" "^### 误报")
legacy_ma_misses=$(count_entries "$LEGACY_MULTIAGENT_FEEDBACK" "^### Miss")
legacy_ma_fps=$(count_entries "$LEGACY_MULTIAGENT_FEEDBACK" "^### False Positive")
legacy_tc_obs=$(count_entries "$LEGACY_TOOLCALL_FEEDBACK" "^### (Positive|Negative)")

# Total entries per dimension (unified + legacy)
total_skill_misses=$((skill_misses + legacy_skill_misses))
total_skill_fps=$((skill_fps + legacy_skill_fps))
total_skill=$((total_skill_misses + total_skill_fps))

total_ma_misses=$((legacy_ma_misses))  # MultiAgent misses are under ## MultiAgentOpt > ### Miss
total_ma_fps=$((legacy_ma_fps))
total_ma=$((total_ma_misses + total_ma_fps))

total_tc_obs=$((legacy_tc_obs))
# ToolCall has unified entries too (counted under ## ToolCallOpt > ### Positive/Negative)
tc_positive=$(count_entries "$FEEDBACK" "^### Positive")
tc_negative=$(count_entries "$FEEDBACK" "^### Negative")
total_tc_obs=$((total_tc_obs + tc_positive + tc_negative))

meta_raw=$(read_meta)
sessions=$(echo "$meta_raw" | "$PY" -c "import sys,json; print(json.loads(sys.stdin.read()).get('sessions',0))" 2>/dev/null || echo 0)
sessions=$((sessions + 1))
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# --- Create initial feedback.md if needed ---
if [ ! -f "$FEEDBACK" ]; then
  cat > "$FEEDBACK" <<- 'FEOF'
# Training Loop Feedback

## SkillOpt — Skill Trigger Accuracy
### Miss
### False Positive

## MultiAgentOpt — Agent Dispatch Accuracy
### Miss
### False Positive

## ToolCallOpt — Tool Call Pattern Quality
### Positive
### Negative
FEOF
fi

# --- Write unified meta.json ---
"$PY" -c "
import json
d = {
  'sessions': $sessions,
  'last_session': '$now',
  'last_optimized': '',
  'dimensions': {
    'skill': {
      'misses': $total_skill_misses,
      'false_positives': $total_skill_fps,
      'total': $total_skill,
      'threshold': 3,
      'last_optimized': ''
    },
    'multiagent': {
      'misses': $total_ma_misses,
      'false_positives': $total_ma_fps,
      'total': $total_ma,
      'threshold': 3,
      'last_optimized': ''
    },
    'toolcall': {
      'observations': $total_tc_obs,
      'total': $total_tc_obs,
      'threshold': 3,
      'last_optimized': ''
    }
  }
}
json.dump(d, open(r'$META', 'w', encoding='utf-8'), indent=2, ensure_ascii=False)
"

# --- Emit threshold alerts ---
alerts=()

if [ "$total_skill" -ge 3 ]; then
  alerts+=("[SkillOpt] $total_skill/3 signals (m=$total_skill_misses fp=$total_skill_fps). Review skill trigger rules in CLAUDE.md.")
fi

if [ "$total_ma" -ge 3 ]; then
  alerts+=("[MultiAgentOpt] $total_ma/3 signals (m=$total_ma_misses fp=$total_ma_fps). Review multiagent scoring rules.")
fi

if [ "$total_tc_obs" -ge 3 ]; then
  alerts+=("[ToolCallOpt] $total_tc_obs/3 observations. Review tool call patterns in training-loop/feedback.md.")
fi

if [ ${#alerts[@]} -gt 0 ]; then
  for alert in "${alerts[@]}"; do
    echo "[TrainingLoop] $alert" >&2
  done
fi

# --- Session-end reflection prompt ---
cat >&2 <<- 'EOM'
[TrainingLoop] 本轮行为质量反思 (统一训练系统):
  SkillOpt: skill 触发是否正确？→ 记录到 training-loop/feedback.md ## SkillOpt
  MultiAgentOpt: agent 分发是否准确？→ 记录到 ## MultiAgentOpt
  ToolCallOpt: 工具调用效率如何？→ 记录到 ## ToolCallOpt
  正/负样本均可，积累 3 条触发 SessionStart 提醒。
EOM

echo "[TrainingLoop] Session #$sessions — skill=$total_skill ma=$total_ma tc=$total_tc_obs"
echo '{"continue":true,"suppressOutput":true}'
