#!/usr/bin/env bash
# Multi-agent auto-detector — UserPromptSubmit hook
# Heavy mode v2: Two-phase judgment for dispatching parallel agents.
# Phase 1: Fast heuristic filter (zero API cost, filters ~95% of chat/greetings).
# Phase 2: Lightweight heuristic enhancement (v1 fallback) / LLM classifier (future).
# Injects structured suggestion via additionalContext only when multiagent is likely.
# Supports --dry-run for scoring visualization.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# Threshold constants — adjustable by training-collect.py --apply-thresholds
PHASE1_TRIGGER_MIN=4
PHASE2_TRIGGER_MIN=3
export PHASE1_TRIGGER_MIN PHASE2_TRIGGER_MIN

export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

INPUT=$(cat)

# --- dry-run mode: print scoring breakdown for the given input text ---
if [ "${1:-}" = "--dry-run" ]; then
    echo "[lean-hooks] multiagent-detect --dry-run mode"
    echo "Reading input from stdin..."
    echo ""
    # Pass the input through with DRY_RUN flag
    DRY_RUN=1 HOOK_INPUT="$INPUT" PHASE1_TRIGGER_MIN="$PHASE1_TRIGGER_MIN" PHASE2_TRIGGER_MIN="$PHASE2_TRIGGER_MIN" "$PY" - <<'PYEOF'
import json, os, re, sys

# Read thresholds from env
PHASE1_TRIGGER_MIN = int(os.environ.get("PHASE1_TRIGGER_MIN", "4"))
PHASE2_TRIGGER_MIN = int(os.environ.get("PHASE2_TRIGGER_MIN", "3"))

# Same configuration as main run
ENABLE_PHASE_2 = True
WEIGHTS = {
    "strong_multiagent": 3, "moderate_multiagent": 2, "weak_multiagent": 1,
    "structure_bonus": 1, "short_penalty": -3, "greeting_penalty": -2,
}
STRONG = ["parallel agents", "parallel agent", "同时处理", "多个 agent", "多个agent", "dispatch agents", "并行 agent", "并行agent", "parallel tasks", "parallel execution", "role-collab", "多角色协同", "并行审查"]
MODERATE = ["fix A and refactor B", "fix and refactor", "implement and test", "review and merge", "一边.*一边", "同时.*和.*", "一起.*和.*", "both.*and.*", "fix.*then.*add"]
WEAK = ["能不能.*然后", "能不能.*再", "先.*然后.*再", "please.*then.*", "also.*need.*", "in addition", "additionally", "还有.*需要.*", "另外.*还要.*"]
GREETINGS = ["hello", "hi", "hey", "你好", "您好", "早上好", "晚上好", "在吗", "在嘛"]

def phase1_score(text, text_lower):
    score = 0; reasons = []
    if len(text) < 40:
        score += WEIGHTS["short_penalty"]; reasons.append("short")
    elif len(text) > 200 and text.count("。") + text.count("，") + text.count(".") >= 3:
        score += WEIGHTS["structure_bonus"]; reasons.append("structure")
    for g in GREETINGS:
        if text_lower.startswith(g):
            score += WEIGHTS["greeting_penalty"]; reasons.append("greeting"); break
    for kw in STRONG:
        if re.search(kw, text_lower):
            score += WEIGHTS["strong_multiagent"]; reasons.append("strong_keyword"); break
    for kw in MODERATE:
        if re.search(kw, text_lower):
            score += WEIGHTS["moderate_multiagent"]; reasons.append("moderate_keyword"); break
    for kw in WEAK:
        if re.search(kw, text_lower):
            score += WEIGHTS["weak_multiagent"]; reasons.append("weak_keyword"); break
    return score, reasons

def phase2_heuristic(text, text_lower, score, reasons):
    task_verbs = len(re.findall(r"\b(fix|refactor|implement|add|update|remove|move|rename|create|generate|build|test|review|merge|deploy|optimize|convert|migrate|restructure)\b", text_lower))
    file_refs = len(re.findall(r"\b[\w\-/]+\.(py|js|ts|jsx|tsx|rs|go|java|kt|swift|rb|php|cs|cpp|c|h|hpp|yaml|yml|json|toml|md|sh|sql)\b", text_lower))
    if task_verbs >= 2: score += 1; reasons.append("multi_verb")
    if file_refs >= 2: score += 1; reasons.append("multi_file")
    if "strong_keyword" in reasons and task_verbs < 2 and file_refs < 2:
        score -= 1; reasons.append("isolated_strong")
    return score, reasons

try:
    data = json.loads(os.environ["HOOK_INPUT"])
except Exception:
    data = {}

prompt = data.get("prompt", "") or ""
if not prompt:
    prompt = sys.stdin.read() or ""
text = prompt.strip()
text_lower = text.lower()

print(f"Input text ({len(text)} chars): {text[:200]}{'...' if len(text) > 200 else ''}")
print()

score, reasons = phase1_score(text, text_lower)
print(f"Phase 1 score: {score}")
print(f"  Reasons: {', '.join(reasons) if reasons else 'none'}")

if ENABLE_PHASE_2:
    if 2 <= score < PHASE1_TRIGGER_MIN:
        score, reasons = phase2_heuristic(text, text_lower, score, reasons)
        print(f"Phase 2 score: {score}")
    else:
        print(f"Phase 2: skipped (score not in [2,{PHASE1_TRIGGER_MIN}) range)")
    print(f"  Reasons: {', '.join(reasons) if reasons else 'none'}")

# Determine effective threshold
if ENABLE_PHASE_2 and any(r in reasons for r in ("multi_verb", "multi_file")):
    effective_threshold = PHASE2_TRIGGER_MIN
else:
    effective_threshold = PHASE1_TRIGGER_MIN

print(f"\nFinal score: {score}")
print(f"Effective threshold: {effective_threshold} (P1={PHASE1_TRIGGER_MIN}, P2={PHASE2_TRIGGER_MIN})")
print(f"Decision: {'TRIGGER — suggest parallel agents' if score >= effective_threshold else 'NO TRIGGER'}")
PYEOF
    exit 0
fi

HOOK_INPUT="$INPUT" "$PY" - <<'PYEOF'
import json
import os
import re
import sys
import time

# --- Session-level state machine ---
STATE_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "data")
os.makedirs(STATE_DIR, exist_ok=True)
STATE_FILE = os.path.join(STATE_DIR, "multiagent_session_state.json")

SESSION_IDLE_TIMEOUT_SECONDS = 300  # 5 min without interaction = reset

def load_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {"state": "idle", "task_context": "", "last_prompt_start": 0}

def save_state(s):
    s["last_prompt_start"] = time.time()
    try:
        with open(STATE_FILE, "w", encoding="utf-8") as f:
            json.dump(s, f, indent=2)
    except Exception:
        pass

def reset_state(reason="idle"):
    return {"state": "idle", "task_context": "", "last_prompt_start": 0}

def extract_keywords(text_lower):
    return set(re.findall(r'\b[\w一-鿿]{2,}\b', text_lower))

def detect_continuation(state, text_lower):
    """Returns (is_continuation, reason_str, penalty_score)"""
    if state.get("state") == "idle":
        return False, "idle", 0

    # Idle timeout?
    last_time = state.get("last_prompt_start", 0)
    if last_time and (time.time() - last_time) > SESSION_IDLE_TIMEOUT_SECONDS:
        return False, "idle_timeout", 0

    # --- Layer 1: explicit continuation markers (Chinese + English) ---
    continuation_markers = [
        (r'^(这个|那个|它|刚才的|之前的|上面的)\b', 'pronoun_reference'),
        (r'^(能不能|能不能把|能不能再|能不能给我|能否|可否|要不|改成|换成|改为)\b', 'request_retry'),
        (r'^(还有|另外|对了|那|然后|接着|继续|下一步|然后呢)\b', 'continuation_word'),
        (r'^(为什么|怎么|怎么没|是不是|有没有|对吗|对吗\?|为何|如何)\b', 'question'),
        (r'^(改一下|修一下|换一下|保存|重启|删了|去掉|加上|添加)\b', 'imperative_no_subject'),
        (r'^(继续|接着来|下一步|然后呢|ok|好的|对|收到|搞定|完成)\b$', 'one_word_continuation'),
        (r'^不错|^可以|^行|^好|^嗯|^哦', 'affirmation'),
    ]
    for pattern, reason in continuation_markers:
        if re.search(pattern, text_lower):
            return True, reason, -3

    # --- Layer 2: keyword overlap with active task context ---
    prev_kw = state.get("task_keywords", [])
    if prev_kw:
        curr_kw = extract_keywords(text_lower)
        prev_set = set(prev_kw)
        overlap = prev_set & curr_kw if curr_kw else set()
        if prev_set and len(overlap) / len(prev_set) > 0.5:
            return True, f"keyword_overlap_{len(overlap)/len(prev_set):.0%}", -2

    # --- Layer 3: follow-up question patterns ---
    followups = [r'\?$', r'^(那|所以|然后呢|那接下来|接下来|之后)']
    for pat in followups:
        if re.search(pat, text_lower):
            return True, "followup_question", -1

    return False, "new_task_or_unclear", 0

def update_state(state, prompt, will_dispatch, score=0, reasons=None, force_match=None):
    if will_dispatch:
        state["state"] = "task_active"
        state["task_context"] = prompt[:200]
        state["task_keywords"] = list(extract_keywords(prompt.lower()))[:20]
        state["last_trigger_score"] = score
        state["last_trigger_reasons"] = reasons or []
        if force_match:
            state["last_force_match"] = force_match
    save_state(state)


# --- CONFIGURATION ---
ENABLE_PHASE_2 = True  # v1: Heuristic fallback enabled. Set False for Phase 1 only.
                       # Future: set True and swap in phase2_llm_classifier() for LLM-based.

# Heuristic weights (conservative by default)
WEIGHTS = {
    "strong_multiagent": 3,
    "moderate_multiagent": 2,
    "weak_multiagent": 1,
    "structure_bonus": 1,
    "short_penalty": -3,
    "greeting_penalty": -2,
}

# Keywords
STRONG = ["parallel agents", "parallel agent", "同时处理", "多个 agent", "多个agent", "dispatch agents", "并行 agent", "并行agent", "parallel tasks", "parallel execution", "role-collab", "多角色协同", "并行审查"]
MODERATE = ["fix A and refactor B", "fix and refactor", "implement and test", "review and merge", "一边.*一边", "同时.*和.*", "一起.*和.*", "both.*and.*", "fix.*then.*add"]
WEAK = ["能不能.*然后", "能不能.*再", "先.*然后.*再", "please.*then.*", "also.*need.*", "in addition", "additionally", "还有.*需要.*", "另外.*还要.*"]
GREETINGS = ["hello", "hi", "hey", "你好", "您好", "早上好", "晚上好", "在吗", "在嘛"]

def phase1_score(text, text_lower):
    score = 0
    reasons = []

    if len(text) < 40:
        score += WEIGHTS["short_penalty"]
        reasons.append("short")
    elif len(text) > 200 and text.count("。") + text.count("，") + text.count(".") >= 3:
        score += WEIGHTS["structure_bonus"]
        reasons.append("structure")

    for g in GREETINGS:
        if text_lower.startswith(g):
            score += WEIGHTS["greeting_penalty"]
            reasons.append("greeting")
            break

    for kw in STRONG:
        if re.search(kw, text_lower):
            score += WEIGHTS["strong_multiagent"]
            reasons.append("strong_keyword")
            break

    for kw in MODERATE:
        if re.search(kw, text_lower):
            score += WEIGHTS["moderate_multiagent"]
            reasons.append("moderate_keyword")
            break

    for kw in WEAK:
        if re.search(kw, text_lower):
            score += WEIGHTS["weak_multiagent"]
            reasons.append("weak_keyword")
            break

    return score, reasons

def phase2_heuristic(text, text_lower, score, reasons):
    task_verbs = len(re.findall(r"\b(fix|refactor|implement|add|update|remove|move|rename|create|generate|build|test|review|merge|deploy|optimize|convert|migrate|restructure)\b", text_lower))
    file_refs = len(re.findall(r"\b[\w\-/]+\.(py|js|ts|jsx|tsx|rs|go|java|kt|swift|rb|php|cs|cpp|c|h|hpp|yaml|yml|json|toml|md|sh|sql)\b", text_lower))

    if task_verbs >= 2:
        score += 1
        reasons.append("multi_verb")
    if file_refs >= 2:
        score += 1
        reasons.append("multi_file")

    if "strong_keyword" in reasons and task_verbs < 2 and file_refs < 2:
        score -= 1
        reasons.append("isolated_strong")

    return score, reasons

def phase2_llm_classifier(text):
    return None

# --- Force trigger: explicit user request for parallel agents ---
FORCE_PATTERNS = [
    r"并行执行",
    r"拆分成子任务",
    r"拆分.*并行",
    r"同时.*多个任务",
    r"分成.*agent",
    r"强制.*multiagent",
    r"force.*multiagent",
    r"dispatch.*parallel",
    r"parallel.*agents?",
    r"多个.*并行",
]

def is_force_trigger(text_lower):
    for pat in FORCE_PATTERNS:
        if re.search(pat, text_lower):
            return pat
    return None

# --- New-task signals during active session ---
# When session state is task_active, some user messages are actually NEW
# independent tasks disguised as follow-ups. These patterns override
# continuation detection so multiagent can still trigger.
NEW_TASK_PATTERNS = [
    r"^(另外|还有|对了|顺便).*?(需要|帮我|做|写|修|改|查|找|测试|实现|添加|分析)",
    r"^(再|另外再|顺便再|接下来再).*?(帮我|做|写|修|改|查|找|测试|实现|添加)",
    r"(新任务|新需求|另一个|另外一个|新功能).*?(需要|帮我|做|写|修|改|查|找|测试)",
    r"^(除了这个|除了.*之外).*?(还|另外|也|再)",
]

def is_new_task_during_active_session(state, text_lower):
    if state.get("state") != "task_active":
        return False
    for pat in NEW_TASK_PATTERNS:
        if re.search(pat, text_lower):
            return pat
    return False

def build_suggestion(score, reasons, text, force_match=None, new_task_override=None):
    # Static injection text for cache stability — detailed score/reasons logged to state file only
    lines = [
        "[MultiAgent Hook - ASK USER] 检测到您的请求可能包含多个独立任务，建议先询问用户是否并行执行。",
    ]
    # Score and force_match details logged to state file, not injected
    lines.extend([
        "",
        "==> 请在回复中使用 AskUserQuestion 工具向用户确认：",
        '    问题: "检测到您的请求包含多个可并行的独立任务，是否拆分成子任务并行执行？"',
        "    选项:",
        "      [是，拆分成并行Agent执行] — 确认后使用 dispatching-parallel-agents pattern 分配子任务",
        "      [否，当前会话串行处理] — 继续单Agent处理",
        "",
        "  规则:",
        "    - 用户选'是' → 立即 dispatch 并行 agents，不要重复询问",
        "    - 用户选'否' → 正常单 agent 处理，不 dispatch",
        "    - 用户忽略或反问 → 视为'否'，继续单 agent 处理",
        "",
        "如果此判断有误，说 'multiagent false positive' 帮助改进规则。",
    ])
    return "\n".join(lines)

# Read thresholds from shell env (exported above), with defaults
import os
PHASE1_TRIGGER_MIN = int(os.environ.get("PHASE1_TRIGGER_MIN", "4"))
PHASE2_TRIGGER_MIN = int(os.environ.get("PHASE2_TRIGGER_MIN", "3"))

try:
    data = json.loads(os.environ["HOOK_INPUT"])
except Exception:
    sys.exit(0)

prompt = data.get("prompt", "") or ""
text = prompt.strip()
text_lower = text.lower()

# Load session state
state = load_state()
is_continuation, reason, penalty = detect_continuation(state, text_lower)

# --- Force trigger check (bypasses normal scoring) ---
force_match = is_force_trigger(text_lower)

# --- New-task-in-the-middle check ---
new_task_match = is_new_task_during_active_session(state, text_lower)

score, reasons = phase1_score(text, text_lower)

if ENABLE_PHASE_2 and 2 <= score < PHASE1_TRIGGER_MIN:
    score, reasons = phase2_heuristic(text, text_lower, score, reasons)

# Apply continuation penalty
if is_continuation:
    if new_task_match:
        score = max(score, 0)
        reasons.append(f"new_task_override({new_task_match})")
    else:
        score += penalty
        score = max(0, score)
        reasons.append(f"continuation({reason}):{penalty}")

# After Phase 2, use lower threshold (PHASE2_TRIGGER_MIN)
# Determine which threshold applies
if ENABLE_PHASE_2 and any(r in reasons for r in ("multi_verb", "multi_file")):
    effective_threshold = PHASE2_TRIGGER_MIN
else:
    effective_threshold = PHASE1_TRIGGER_MIN

# Dispatch if score meets threshold or force trigger
effective_continuation = is_continuation and not new_task_match
will_dispatch = (not effective_continuation) and (score >= effective_threshold or force_match)

if will_dispatch:
    suggestion = build_suggestion(score, reasons, text, force_match=force_match, new_task_override=new_task_match)
    out = {
        "continue": True,
        "suppressOutput": True,
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": suggestion
        }
    }
    print(json.dumps(out, ensure_ascii=False))
else:
    print(json.dumps({"continue": True, "suppressOutput": True}))

# Persist state machine (with debug info logged to state file only)
update_state(state, prompt, will_dispatch, score=score, reasons=reasons, force_match=force_match)
PYEOF
