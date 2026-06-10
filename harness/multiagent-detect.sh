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

if ENABLE_PHASE_2 and 2 <= score < 4:
    score, reasons = phase2_heuristic(text, text_lower, score, reasons)

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
