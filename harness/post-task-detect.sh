#!/usr/bin/env bash
# Post-task completion detector — UserPromptSubmit hook
# Heavy mode v2: detects completion signals in user prompt and injects a
# reminder to AI context. The AI still judges whether to actually write
# memory / record feedback (per CLAUDE.md §6.1 + §6.2).
# Uses Anaconda python explicitly (MINGW64 python3 stub exits 49).
# Sets PYTHONIOENCODING=utf-8 to keep JSON output valid UTF-8.
set -euo pipefail

export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

PY="D:/jiqixuexi/anaconda/python.exe"

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
        "[Post-Task Hook] 任务完成。执行三层写入检查:\n"
        "  Tier 1 (auto): 本轮有实质操作(Edit/Write/Bash/修复/部署)有?\n"
        "   有 -> echo '{\"project\":\"...\",\"summary\":\"...\",\"files\":\"...\"}' | python D:/claude-ecosystem/config/harness/auto-summary.py\n"
        "    纯聊天/无实质 -> echo '{\"has_substance\":false}' | python D:/claude-ecosystem/config/harness/auto-summary.py\n"
        "  Tier 2 (manual): 用户明确说了 记住/save/remember ?-> 写入 memory/*.md\n"
        "  TrainingLoop: 本轮行为质量有值得记录的？→ 写入 training-loop/feedback.md\n"
        "    ## SkillOpt: skill 触发准确/误报？\n"
        "    ## MultiAgentOpt: agent 分发恰当/遗漏？\n"
        "    ## ToolCallOpt: 工具调用效率如何？\n"
        "    正/负样本均可，积累 3 条触发 SessionStart 提醒。"
    )

if ma_feedback:
    reminders.append(
        f"[MultiAgentOpt] Detected {ma_feedback} feedback.\n"
        f"  Record to config/multiagent-feedback/feedback.md:\n"
        f"    ### {ma_feedback.replace('_', ' ').title().replace('False Positive', 'False Positive')}\n"
        f"    - 任务描述: ...\n"
        f"    - {'原因: 用户消息不该触发但触发了' if ma_feedback == 'false_positive' else '期望: 用户消息本该触发但遗漏了'}\n"
        f"  累积 3 条后 session-start 将提醒优化 multiagent-detect 评分规则。"
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
