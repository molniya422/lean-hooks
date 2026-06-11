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

export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

INPUT=$(cat)

# --- dry-run mode: print scoring breakdown for the given input text ---
if [ "${1:-}" = "--dry-run" ]; then
    echo "[lean-hooks] multiagent-detect --dry-run mode"
    echo "Reading input from stdin..."
    echo ""
    # Pass the input through with DRY_RUN flag
    DRY_RUN=1 HOOK_INPUT="$INPUT" "$PY" - <<'PYEOF'
import json, os, re, sys

# Same configuration as main run
ENABLE_PHASE_2 = True
WEIGHTS = {
    "strong_multiagent": 3, "moderate_multiagent": 2, "weak_multiagent": 1,
    "structure_bonus": 1, "short_penalty": -3, "greeting_penalty": -2,
}
STRONG = ["parallel agents", "parallel agent", "同时处理", "多个 agent", "多个agent", "dispatch agents", "并行 agent", "并行agent", "parallel tasks", "parallel execution"]
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
    if 2 <= score < 4:
        score, reasons = phase2_heuristic(text, text_lower, score, reasons)
        print(f"Phase 2 score: {score}")
    else:
        print("Phase 2: skipped (score not in [2,4) range)")
    print(f"  Reasons: {', '.join(reasons) if reasons else 'none'}")

print(f"\nFinal score: {score}")
print(f"Decision: {'TRIGGER (>= 4) — suggest parallel agents' if score >= 4 else 'NO TRIGGER (< 4)'}")
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

def update_state(state, prompt, will_dispatch):
    if will_dispatch:
        state["state"] = "task_active"
        state["task_context"] = prompt[:200]
        state["task_keywords"] = list(extract_keywords(prompt.lower()))[:20]
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
STRONG = ["parallel agents", "parallel agent", "同时处理", "多个 agent", "多个agent", "dispatch agents", "并行 agent", "并行agent", "parallel tasks", "parallel execution"]
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

def build_suggestion(score, reasons, text, force_match=None):
    if force_match:
        lines = [
            "[MultiAgent Hook - FORCED] Explicit parallel dispatch request detected.",
            f"Force pattern: {force_match}",
            "DISPATCH PARALLEL AGENTS NOW — use Agent tool with dispatching-parallel-agents pattern:",
            "  Agent A: [task 1] -> do X",
            "  Agent B: [task 2] -> do Y",
            "  Then: synthesize results",
        ]
    else:
        lines = [
            "[MultiAgent Hook] This message looks like it contains multiple independent tasks.",
            f"Score: {score} | Reasons: {', '.join(reasons)}",
            "Consider dispatching parallel agents:",
            "  Agent A: [task 1] -> do X",
            "  Agent B: [task 2] -> do Y",
            "  Then: synthesize results",
            "",
            "If this assessment is wrong, say 'multiagent false positive' to help improve the heuristic.",
        ]
    return "\n".join(lines)

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

score, reasons = phase1_score(text, text_lower)

if ENABLE_PHASE_2 and 2 <= score < 4:
    score, reasons = phase2_heuristic(text, text_lower, score, reasons)

# Apply continuation penalty
if is_continuation:
    score += penalty
    score = max(0, score)
    reasons.append(f"continuation({reason}):{penalty}")

will_dispatch = (not is_continuation) and (score >= 4 or force_match)

if will_dispatch:
    suggestion = build_suggestion(score, reasons, text, force_match=force_match)
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

# Persist state machine
update_state(state, prompt, will_dispatch)
PYEOF
