#!/usr/bin/env bash
# Post-task completion detector — UserPromptSubmit hook
# Heavy mode v2: detects completion signals in user prompt and injects a
# reminder to AI context. The AI still judges whether to actually write
# memory / record feedback (per CLAUDE.md §6.1 + §6.2).
# Sources harness/env.sh for $PY (Python) and $HARNESS_ROOT.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

INPUT=$(cat)

HOOK_INPUT="$INPUT" "$PY" - <<'PYEOF'
import json
import os
import re
import sys

try:
    data = json.loads(os.environ["HOOK_INPUT"])
except Exception:
    sys.exit(0)

# --- DISABLED HOOKS CHECK ---
# Users can temporarily disable this hook via: export DISABLED_HOOKS="post-task-detect"
# or comma-separated: export DISABLED_HOOKS="post-task-detect,multiagent-detect"
disabled = os.environ.get("DISABLED_HOOKS", "")
if "post-task" in disabled.lower() or "post-task-detect" in disabled.lower():
    print(json.dumps({"continue": True, "suppressOutput": True}))
    sys.exit(0)

prompt = data.get("prompt", "") or ""
text = prompt.strip()
text_lower = text.lower()

# --- 1. Hard exclusions: never treat as completion ---
def is_excluded(text, text_lower):
    # 1a. Trailing question (Chinese or English): "搞定吗？" "fixed it?"
    if re.search(r"[吗呢？\?]\s*$", text):
        return True
    # 1b. Slash-enumeration suggests listing concepts: "修好/搞定/完成"
    if text.count("/") >= 2:
        return True
    # 1c. Quoted completion word: "修好" 或 'done'
    if re.search(r'[""「」\'\'][^"\']*(完成|搞定|修好|解决|好了|成了|done|fixed|finished|solved|shipped|merged|deployed)[^"\']*[""「」\'\']', text, re.IGNORECASE):
        return True
    # 1d. Meta-discussion markers: "是什么意思" "什么意思" "哪些" "how about"
    meta_markers = ["是什么意思", "什么意思", "哪些", "有哪些", "同义", "相同", "语义", "相等", "近义", "等价"]
    for m in meta_markers:
        if m in text:
            return True
    if re.search(r"\b(what|which|how about|how do|what about)\b", text_lower):
        return True
    return False

# --- 2. Soft negation/intention in proximity to match ---
NEGATIONS = ["没", "未", "不", "还没", "没有", "无法", "不能", "别", "don't", "didn't", "not", "no", "n't"]
INTENTIONS = ["想", "打算", "准备", "试试", "看看", "尝试", "让我", "怎么", "要不要", "能不能",
              "want to", "going to", "try to", "let's", "should i", "could we", "how to"]

def has_negation_or_intention(text_lower, word_pos, window=5):
    start = max(0, word_pos - window)
    prefix = text_lower[start:word_pos]
    for neg in NEGATIONS:
        if neg in prefix:
            return True
    for intent in INTENTIONS:
        if intent in prefix:
            return True
    return False

# --- 3. Pattern lists ---
# End-anchored strong completion (most common)
STRONG_END = [
    # Chinese
    r"修好[了啦]?[。!！,]?$",
    r"搞定[了]?[。!！,]?$",
    r"完成[了]?[。!！,]?$",
    r"解决[了]?[。!！,]?$",
    r"好了[。!！,]?$",
    r"成了[。!！,]?$",
    r"可以[了吧]?[。!！,]?$",
    r"没问题[了]?[。!！,]?$",
    r"行了[。!！,]?$",
    r"齐活[了]?[。!！,]?$",
    r"事成了?[。!！,]?$",
    r"这样就可以了[。!！,]?$",
    r"这样就行了[。!！,]?$",
    r"现在没问题[了]?[。!！,]?$",
    r"ok[。!！,]?$",
    r"ok 了吧?[。!！,]?$",
    r"ok 了[。!！,]?$",
    r"yep[。!！,]?$",
    r"yep 了[。!！,]?$",
    r"yeah[。!！,]?$",
    r"好的[。!！,]?$",
    r"对[，,.。!]?$",
    r"收到[。!！,]?$",
    r"可以了[。!！,]?$",
    r"没问题了[。!！,]?$",
    r"可以用了[。!！,]?$",
    r"能用了[。!！,]?$",
    r"上线了[。!！,]?$",
    r"发布了[。!！,]?$",
    r"部署了[。!！,]?$",
    r"合并了[。!！,]?$",
    r"推送了[。!！,]?$",
    r"提交了[。!！,]?$",
    r"搞定了[。!！,]?$",
    r"修好了[。!！,]?$",
    # English
    r"\b(it['']s? )?done[.!,\s]*$",
    r"\b(it['']s? )?finished[.!,\s]*$",
    r"\b(it['']s? )?fixed[.!,\s]*$",
    r"\b(it['']s? )?solved[.!,\s]*$",
    r"\bshipped[.!,\s]*$",
    r"\bmerged[.!,\s]*$",
    r"\bpushed[.!,\s]*$",
    r"\bcommitted[.!,\s]*$",
    r"\bdeployed[.!,\s]*$",
    r"\breleased[.!,\s]*$",
    r"\bpublished[.!,\s]*$",
    r"\bcompleted?[.!,\s]*$",
    r"\ball set[.!,\s]*$",
    r"\bit works[.!,\s]*$",
    r"\bthat works[.!,\s]*$",
    r"\bworks for me[.!,\s]*$",
    r"\bci (passed|green)[.!,\s]*$",
    r"\btests? pass(ed|ing)?[.!,\s]*$",
    r"\bmerged it[.!,\s]*$",
    r"\bthat['']?s (it|all)[.!,\s]*$",
    r"\b(looking|looks) good[.!,\s]*$",
    r"\bship it[.!,\s]*$",
    r"\bgood to go[.!,\s]*$",
    r"\bsubmitted[.!,\s]*$",
    r"\bpr (is )?(merged|ready|approved)[.!,\s]*$",
]

# Mid-sentence declarative (already-finished markers)
DECLARATIVE = [
    r"已经(修好|搞定|完成|解决|做好|弄好|合并|发布|部署|上线|提交|推送|提交了|合并了|发布了|部署了|上线了)",
    r"现在(搞定|好了|可以了|合并了|发布了|部署了|上线了|提交了|推送了)",
    r"现在(没问题|可以用|能用|可以用了)",
    r"task (is )?(done|finished|complete)[.!,\s]*$",
    r"feature (is )?(done|complete|shipped)",
    r"it['']?s? (now )?working",
    r"build (is )?(green|passing)",
    r"all green",
    r"已经(发布|部署|上线|提交|推送|合并)了?",
    r"已(完成|搞定|修好|解决|合并|发布|部署|上线|提交|推送)了?",
    r"我(已经|已经)(修好|搞定|完成|解决|做好|弄好|合并|发布|部署|上线)",
    r"我(修好|搞定|完成|解决|做好|弄好|合并|发布|部署|上线|提交|推送)了",
    r"刚才(已经)?(修好|搞定|完成|解决)",
]

# Short single-token affirmation (entire message is short)
SHORT_AFFIRM = [
    r"^👍\s*$", r"^🎉\s*$", r"^✓\s*$", r"^✔\s*$",
    r"^ok[。.!！]?$", r"^y[ep]?[。.!！]?$", r"^yes[.!]?$", r"^no[.!]?$",
    r"^好的[。!]?$", r"^对[。!]?$", r"^收到[。!]?$",
    r"^done[.!]?$", r"^thanks?[.!]?$", r"^thx[.!]?$", r"^ty[.!]?$",
    r"^搞定[。!]?$", r"^完成[。!]?$", r"^好了[。!]?$",
]

# --- 4. Decision ---
def is_completion(text, text_lower):
    if is_excluded(text, text_lower):
        return False

    # Short single-token affirmation
    for pat in SHORT_AFFIRM:
        if re.match(pat, text_lower):
            return True

    # End-anchored strong
    for pat in STRONG_END:
        m = re.search(pat, text_lower)
        if m and not has_negation_or_intention(text_lower, m.start()):
            return True

    # Mid-sentence declarative
    for pat in DECLARATIVE:
        m = re.search(pat, text_lower)
        if m and not has_negation_or_intention(text_lower, m.start()):
            return True

    return False

completion = is_completion(text, text_lower)

# --- MultiAgentOpt feedback detector ---
# Detects user providing feedback on multiagent-detect accuracy
MULTIAGENT_FP_KEYWORDS = ["multiagent false positive", "multiagent fp", "multiagent 误报", "multiagent-fp"]
MULTIAGENT_MISS_KEYWORDS = ["multiagent miss", "multiagent 漏报", "multiagent-miss"]

def is_multiagent_feedback(text_lower):
    for kw in MULTIAGENT_FP_KEYWORDS:
        if kw in text_lower:
            return "false_positive"
    for kw in MULTIAGENT_MISS_KEYWORDS:
        if kw in text_lower:
            return "miss"
    return None

ma_feedback = is_multiagent_feedback(text_lower)

# --- Build reminders ---
reminders = []

if completion:
    reminders.append(
        "[Post-Task Hook] Task completion detected. Perform two-tier write check:\n"
        "  Tier 1 (auto): Did this session have substantive work (Edit/Write/Bash/fix/deploy)?\n"
        "   Yes -> echo '{\"project\":\"...\",\"summary\":\"...\",\"files\":\"...\"}' | $PY $HARNESS_ROOT/harness/auto-summary.py\n"
        "   Pure chat -> echo '{\"has_substance\":false}' | $PY $HARNESS_ROOT/harness/auto-summary.py\n"
        "  Tier 2 (manual): Did user explicitly say remember/save? -> write to memory/*.md\n"
        "  SkillOpt: Any skill misses/false positives this session? -> write to $HARNESS_ROOT/skill-feedback/feedback.md"
    )

if ma_feedback:
    reminders.append(
        f"[MultiAgentOpt] Detected {ma_feedback} feedback.\n"
        f"  Record to $HARNESS_ROOT/multiagent-feedback/feedback.md:\n"
        f"    ### {ma_feedback.replace('_', ' ').title().replace('False Positive', 'False Positive')}\n"
        f"    - Task description: ...\n"
        f"    - {'Reason: user message triggered multiagent but should not have' if ma_feedback == 'false_positive' else 'Expected: user message should have triggered multiagent but was missed'}\n"
        f"  After 3 accumulated signals, session-start will remind to optimize multiagent-detect scoring rules."
    )

if reminders:
    combined = "\n\n".join(reminders)
    out = {
        "continue": True,
        "suppressOutput": True,
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": combined
        }
    }
    print(json.dumps(out, ensure_ascii=False))
else:
    print(json.dumps({"continue": True, "suppressOutput": True}))
PYEOF
