#!/usr/bin/env bash
# Multi-agent auto-detector — UserPromptSubmit hook
# Heavy mode v1: Two-phase judgment for dispatching parallel agents.
# Phase 1: Fast heuristic filter (zero API cost, filters ~95% of chat/greetings).
# Phase 2: Lightweight heuristic enhancement (v1 fallback) / LLM classifier (future).
# Injects structured suggestion via additionalContext only when multiagent is likely.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

INPUT=$(cat)

HOOK_INPUT="$INPUT" "$PY" - <<'PYEOF'
import json
import os
import re
import sys

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

    # Length / structure
    if len(text) < 40:
        score += WEIGHTS["short_penalty"]
        reasons.append("short")
    elif len(text) > 200 and text.count("。") + text.count("，") + text.count(".") >= 3:
        score += WEIGHTS["structure_bonus"]
        reasons.append("structure")

    # Greeting exclusion
    for g in GREETINGS:
        if text_lower.startswith(g):
            score += WEIGHTS["greeting_penalty"]
            reasons.append("greeting")
            break

    # Strong
    for kw in STRONG:
        if re.search(kw, text_lower):
            score += WEIGHTS["strong_multiagent"]
            reasons.append("strong_keyword")
            break

    # Moderate
    for kw in MODERATE:
        if re.search(kw, text_lower):
            score += WEIGHTS["moderate_multiagent"]
            reasons.append("moderate_keyword")
            break

    # Weak
    for kw in WEAK:
        if re.search(kw, text_lower):
            score += WEIGHTS["weak_multiagent"]
            reasons.append("weak_keyword")
            break

    return score, reasons

def phase2_heuristic(text, text_lower, score, reasons):
    # Phase 2 is currently a fallback heuristic. In future, this can be an LLM call.
    # For now, we boost score based on task-verb count and file references.
    task_verbs = len(re.findall(r"\b(fix|refactor|implement|add|update|remove|move|rename|create|generate|build|test|review|merge|deploy|optimize|convert|migrate|restructure)\b", text_lower))
    file_refs = len(re.findall(r"\b[\w\-/]+\.(py|js|ts|jsx|tsx|rs|go|java|kt|swift|rb|php|cs|cpp|c|h|hpp|yaml|yml|json|toml|md|sh|sql)\b", text_lower))

    if task_verbs >= 2:
        score += 1
        reasons.append("multi_verb")
    if file_refs >= 2:
        score += 1
        reasons.append("multi_file")

    # Penalty if only one strong hit but no task structure
    if "strong_keyword" in reasons and task_verbs < 2 and file_refs < 2:
        score -= 1
        reasons.append("isolated_strong")

    return score, reasons

def phase2_llm_classifier(text):
    # Future: lightweight local LLM classification here.
    # For now, returns None to indicate no LLM-based classification.
    return None

def build_suggestion(score, reasons, text):
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

score, reasons = phase1_score(text, text_lower)

# Phase 2
if ENABLE_PHASE_2 and 2 <= score < 4:
    score, reasons = phase2_heuristic(text, text_lower, score, reasons)
    # Future: if score still uncertain, call phase2_llm_classifier

if score >= 4:
    suggestion = build_suggestion(score, reasons, text)
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
PYEOF
