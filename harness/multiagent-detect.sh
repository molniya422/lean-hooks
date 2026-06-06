#!/usr/bin/env bash
# Multi-agent auto-detector — UserPromptSubmit hook
# Heavy mode v2: Two-phase judgment for dispatching parallel agents.
# Phase 1: Fast heuristic filter (zero API cost, filters ~95% of chat/greetings).
# Phase 2: Lightweight heuristic enhancement (v1 fallback) / LLM classifier (future).
# Injects structured suggestion via additionalContext only when multiagent is likely.
set -euo pipefail

source "$(dirname "$0")/env.sh"

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
    "definite_not": -5,
    "short_message": -2,
    "greeting": -3,
}

# Thresholds
PHASE1_UNCERTAIN_MIN = 2   # Score above this triggers Phase 2 consideration
PHASE1_TRIGGER_MIN = 4     # Score above this triggers injection WITHOUT Phase 2
PHASE2_TRIGGER_MIN = 3     # Score above this after Phase 2 triggers injection


# --- LLM Phase 2 Interface (Future) ---
# To enable LLM-based classification:
#   1. Set ENABLE_PHASE_2 = True
#   2. Replace the call to phase2_heuristic() with phase2_llm_classifier()
#   3. Implement the LLM call using your API of choice (Anthropic, OpenAI, etc.)
#
# Recommended lightweight call:
#   - Model: Haiku/Flash tier (fast, cheap)
#   - System: "You are a task classifier. Output ONLY a JSON object."
#   - User: prompt text (trimmed to 1500 chars)
#   - Schema: {"multiagent_needed": bool, "confidence": "high|medium|low", "reason": str}
#   - Max tokens: ~30
#   - Expected latency: <300ms (async)
#   - Cost: ~$0.0003 per call at current pricing
#
# Gate: only call LLM if Phase 1 score in [PHASE1_UNCERTAIN_MIN, PHASE1_TRIGGER_MIN).
# This limits LLM calls to ~3-5% of prompts.


try:
    data = json.loads(os.environ["HOOK_INPUT"])
except Exception:
    sys.exit(0)

# --- DISABLED HOOKS CHECK ---
# Users can temporarily disable this hook via: export DISABLED_HOOKS="multiagent-detect"
# or comma-separated: export DISABLED_HOOKS="multiagent-detect,post-task-detect"
disabled = os.environ.get("DISABLED_HOOKS", "")
if "multiagent" in disabled.lower() or "multiagent-detect" in disabled.lower():
    print(json.dumps({"continue": True, "suppressOutput": True}))
    sys.exit(0)

prompt = data.get("prompt", "") or ""
text = prompt.strip()
text_lower = text.lower()


# --- PHASE 1: FAST HEURISTIC FILTER ---

def phase1_score(text, text_lower):
    """
    Returns (score, signals, uncertain).
    Zero-API-cost fast filter.
    """
    score = 0
    signals = []
    uncertain = False

    # 1. Length filter — very short messages are almost never multi-agent tasks
    if len(text) < 30:
        score += WEIGHTS["short_message"]
        signals.append("short_message")
    if len(text) < 10:
        score += WEIGHTS["definite_not"]
        signals.append("too_short")

    # 2. Hard exclusions — never multi-agent (single-turn, greeting, meta)
    exclusion_patterns = [
        r"^(hi+|hello|hey|hola|greetings|yo)[!\.]?$",
        r"^(thanks?|thx|ty)\s*[\.!]?$",
        r"^(ok+d*|okay|kk)\s*[\.!]?$",
        r"^(bye|goodbye|see ya|cya)\s*[\.!]?$",
        r"^(good morning|good afternoon|good evening)",
        r"^(你可以|你能|请|能不能|可不可以).{0,20}[吗\?？]$",
        r"^(what|which|how|who|where|when).{0,30}\?$",
        r"^[🎉👍👎🙏✅❌🔥💡🤔🤷⭐].*$",
    ]
    if not any(c.isalnum() for c in text):
        score += WEIGHTS["definite_not"]
        signals.append("no_alphanum")
    for pat in exclusion_patterns:
        if re.search(pat, text_lower):
            score += WEIGHTS["definite_not"]
            signals.append("excluded_pattern")
            break

    # 3a. Strong multi-agent indicators
    strong_patterns = [
        # English explicit agent talk
        r"\b(parallel|concurrent|simultaneous|at the same time|together|both)\b.*\b(agent|task|worker|subagent)\b",
        r"\b(split|break|divide)\b.*\b(into|among|between)\b.*\b(agent|task|worker|part|subagent)\b",
        r"\b(dispatch|delegate|fan[- ]?out)\b",
        r"\b(multiple|several|many|2|3|4|5|two|three|four|five)\b.*\b(agent|worker|subagent|entity)\b",
        r"\b(subagent|sub-agent|sub_agent|child agent|worker)\b",
        r"\b(dispatching-parallel-agents|parallel agents)\b",
        # Chinese explicit agent/parallel talk — broader verb coverage
        r"(同时|并行|并发|一起|一块儿).{0,15}(处理|做|完成|执行|审查|review|看|分析|写|改|修|重构|优化)",
        r"(分成|拆成|分为|拆分为).{0,15}(几个|多个|两部分|三部分|不同).{0,15}(任务|agent|代理|部分|模块|文件)",
        r"(多个|几个|不同|分别).{0,10}(任务|部分|模块|文件|agent|代理)",
        r"多个.{0,8}agent",
        r"(并行|同时).{0,15}(agent|代理|审查|review|审核|audit)",
        r"让.{0,8}(多个|几个|不同).{0,8}(agent|代理|任务|审查|review)",
        r"\b(orchestrat(e|ion)|coordinat(e|ion))\b.*\b(agent|task|worker)\b",
        # Chinese parallel task without explicit "agent" word
        r"(审查|review|审核|检查).{0,10}(和|与|以及|还有).{0,10}(审查|review|审核|检查|audit)",
        r"分别.{0,15}(处理|做|完成|执行|审查|review|看|分析|写|改|修|重构)",
    ]
    for pat in strong_patterns:
        if re.search(pat, text_lower):
            score += WEIGHTS["strong_multiagent"]
            signals.append(f"strong_match:{pat[:40]}")

    # 3b. Moderate indicators (compound tasks)
    moderate_patterns = [
        r"\b(and|plus|also|meanwhile|while)\b.*\b(fix|refactor|implement|add|build|update|create|write)\b",
        r"\b(fix|refactor|implement|add|build|update|create|write)\b.*\b(and|plus|also|meanwhile)\b.*\b(fix|refactor|implement|add|build|update|create|write)\b",
        r"(修好|搞定|完成).{0,10}(并且|同时|另外|还有).{0,10}(修|搞|做|写|加)",
        r"(写|做|加|改|修).{0,10}(A|B|C|模块A|模块B|文件1|文件2|前端|后端|测试|文档).{0,10}(和|与|以及|还有|并且).{0,10}(写|做|加|改|修)",
        r"\b(all of the above|everything mentioned|all these)\b",
        r"\b(full stack|end[- ]?to[- ]?end)\b.*\b(implementation|feature|task)\b",
    ]
    for pat in moderate_patterns:
        if re.search(pat, text_lower):
            score += WEIGHTS["moderate_multiagent"]
            signals.append(f"moderate_match:{pat[:40]}")

    # 3c. Weak indicators
    weak_patterns = [
        r"\b(agent|AI|bot)\b.*\b(help|assist|work on|handle|take care of)\b",
        r"一边.{0,10}一边",
        r"(先|首先).{0,15}(然后|接着|再|随后).{0,15}(最后|再|又)",
    ]
    for pat in weak_patterns:
        if re.search(pat, text_lower):
            score += WEIGHTS["weak_multiagent"]
            signals.append(f"weak_match:{pat[:40]}")

    # 4. Explicit single-task negation
    single_task_patterns = [
        r"^(just|only|simply|merely)\b",
        r"^(只要|只需|仅仅|只是|简单)",
        r"\b(one thing|single task|just one|only one)\b",
    ]
    for pat in single_task_patterns:
        if re.search(pat, text_lower):
            score += WEIGHTS["definite_not"]
            signals.append("single_task_marker")

    # 5. Message complexity indicators
    sentence_count = len(re.split(r'[。！？\.!?]+', text.strip()))
    if sentence_count >= 3 and len(text) > 200:
        score += 1
        signals.append("multi_sentence_complex")

    # Determine uncertainty
    has_strong = any(s.startswith("strong_match") for s in signals)
    has_moderate = any(s.startswith("moderate_match") for s in signals)
    if has_strong or has_moderate:
        if PHASE1_UNCERTAIN_MIN <= score < PHASE1_TRIGGER_MIN:
            uncertain = True

    return score, signals, uncertain


score1, signals1, uncertain = phase1_score(text, text_lower)


# --- PHASE 2: HEURISTIC ENHANCEMENT (v1 fallback) ---

def phase2_heuristic(text, text_lower, score1, signals1):
    """
    Lightweight heuristic enhancement when Phase 1 is uncertain.
    No API calls. Uses structural analysis.
    """
    score = score1
    signals = list(signals1)

    # 2a. Structural complexity: count distinct task verbs
    task_verbs = re.findall(
        r'\b(implement|fix|refactor|build|create|write|add|update|delete|'
        r'remove|migrate|optimize|test|deploy|configure|set up|debug|design|'
        r'review|audit)\b',
        text_lower
    )
    unique_verbs = len(set(task_verbs))
    if unique_verbs >= 3:
        score += 2
        signals.append(f"three_plus_verbs:{unique_verbs}")
    elif unique_verbs == 2:
        score += 1
        signals.append("two_verbs")
    elif unique_verbs == 0 and score1 < 3:
        score -= 2
        signals.append("no_task_verbs")

    # 2b. File or module references
    file_refs = re.findall(
        r'[A-Za-z0-9_\-\.]+\.(py|js|ts|jsx|tsx|rs|go|java|cpp|c|h|yaml|yml|'
        r'json|toml|md|sh)\b',
        text_lower
    )
    module_refs = re.findall(
        r'\b(module|package|crate|service|component|controller|model|view|'
        r'api|lib|util|helper)\b',
        text_lower
    )
    if len(file_refs) >= 2 or len(module_refs) >= 2:
        score += 1
        signals.append("multi_file_refs")
    if len(file_refs) >= 4:
        score += 1
        signals.append("many_file_refs")

    # 2c. Technology boundary indicators
    tech_count = 0
    tech_groups = [
        ["frontend", "backend", "client", "server"],
        ["react", "vue", "angular", "svelte"],
        ["node", "express", "django", "flask", "fastapi", "spring"],
        ["python", "javascript", "typescript", "rust", "go", "java", "cpp"],
        ["docker", "kubernetes", "terraform", "aws", "gcp"],
        ["database", "db", "sql", "postgres", "mysql", "mongodb"],
    ]
    for group in tech_groups:
        if any(tech in text_lower for tech in group):
            tech_count += 1
    if tech_count >= 2:
        score += 1
        signals.append("tech_boundary")

    # 2d. Explicit timeline / sequencing
    if re.search(
        r'\b(first|then|after|finally|next|step|phase|round|'
        r'迭代|阶段|步骤)\b',
        text_lower
    ):
        score += 1
        signals.append("sequencing")

    # 2e. Dampening: isolated strong signal without structural support
    # Only dampen if Phase 1 score is high (>=4) but there's no structural support
    if score1 >= 4 and not (unique_verbs >= 2 or len(file_refs) >= 2):
        score -= 1
        signals.append("isolated_signal_dampen")

    return score, signals


# Phase 2 decision logic
if uncertain and ENABLE_PHASE_2:
    score2, signals2 = phase2_heuristic(text, text_lower, score1, signals1)
else:
    # Not uncertain, or Phase 2 disabled
    score2, signals2 = score1, signals1

final_score = score2
final_signals = signals2


# --- LLM INTERFACE (Future — commented placeholder) ---
# def phase2_llm_classifier(text, text_lower, score1, signals1):
#     """
#     Phase 2 using LLM classifier.
#     Call lightweight model for uncertain cases.
#     """
#     # Truncate to save tokens
#     truncated = text[:1500]
#
#     system_prompt = (
#         "You are a task intent classifier. Analyze whether the user's prompt "
#         "describes a complex task that would benefit from multiple parallel "
#         "AI agents working on different sub-tasks. Return ONLY JSON."
#     )
#     user_prompt = f"Classify this task:\n\n{truncated}"
#
#     # <-- insert API call here -->
#     # response = call_llm(system=system_prompt, user=user_prompt, max_tokens=30)
#     # parsed = json.loads(response)
#     #
#     # If parsed["multiagent_needed"] is True and parsed["confidence"] != "low":
#     #     return score1 + 2, signals1 + ["llm_confirmed"]
#     # else:
#     #     return score1, signals1 + ["llm_rejected"]
#
#     return score1, signals1  # placeholder


# --- FINAL DECISION ---
# Determine which threshold applies
if uncertain and ENABLE_PHASE_2:
    trigger_threshold = PHASE2_TRIGGER_MIN
else:
    trigger_threshold = PHASE1_TRIGGER_MIN

if final_score < trigger_threshold:
    print(json.dumps({"continue": True, "suppressOutput": True}))
    sys.exit(0)


# --- GENERATE STRUCTURED SUGGESTION ---
def suggest_agent_decomposition(text_lower, signals):
    """
    Map detected signals to a suggested agent decomposition.
    """
    suggestions = []

    if re.search(
        r'\b(test|spec|tdd|jest|pytest|unit test|integration test)\b|'
        r'(测试|test|jest|pytest|单元测试|集成测试|自动化测试|覆盖率|覆盖)',
        text_lower
    ):
        suggestions.append(("test", "编写测试覆盖"))
    if re.search(
        r'\b(fix|bug|debug|error|crash|broken|fail|issue)\b',
        text_lower
    ):
        suggestions.append(("debug", "Investigate and fix the reported issue"))
    if re.search(
        r'\b(refactor|clean|simplif|optimize|performance|perf|quality|'
        r'audit|review)\b',
        text_lower
    ):
        suggestions.append(("review", "Audit and refactor for quality/performance"))
    if re.search(
        r'\b(document|doc|readme|comment|guide|spec)\b',
        text_lower
    ):
        suggestions.append(("docs", "Update documentation and comments"))
    if re.search(
        r'\b(deploy|ci|cd|build|pipeline|docker|kube|terraform|infra)\b',
        text_lower
    ):
        suggestions.append(("infra", "Handle CI/CD, build, or deployment changes"))
    if re.search(
        r'\b(implement|build|create|write|add|feature|function|component)\b',
        text_lower
    ):
        suggestions.append(("code", "Implement the core feature or changes"))

    # Fallback
    if not suggestions:
        suggestions = [
            ("code", "Implement the requested changes"),
            ("review", "Review and validate the implementation"),
        ]

    # Build feedback path from HARNESS_ROOT
    harness_root = os.environ.get("HARNESS_ROOT", "$HARNESS_ROOT")
    feedback_path = os.path.join(harness_root, "multiagent-feedback", "feedback.md")

    lines = [
        f"[MultiAgent Hook] 该提示可能受益于并行 Agent 分发。",
        f"置信度: {final_score}/{trigger_threshold} (超过阈值 +{final_score - trigger_threshold})",
        f"检测信号: {', '.join(final_signals[:6])}",
        "",
        "建议分解:",
    ]
    for role, task_desc in suggestions[:3]:
        lines.append(f"  - {role}: {task_desc}")
    lines.extend([
        "",
        "若使用 dispatching-parallel-agents skill:",
        "  1. 将用户请求拆分为独立的子任务",
        "  2. 为每个子任务分配一个带有明确角色的 agent",
        "  3. 合并结果到统一回复",
        "  4. 仅当子任务真正可并行且无状态依赖时才分发",
    ])

    # --- MultiAgentOpt Feedback Prompt (v2) ---
    lines.extend([
        "",
        "[MultiAgentOpt] 反馈: 若此建议不合理,说 \"multiagent false positive\",",
        "  若 AI 认为本该触发但未触发,说 \"multiagent miss\",",
        f"  将自动记录到 {feedback_path} 以优化评分规则。",
    ])

    return "\n".join(lines)


suggestion_text = suggest_agent_decomposition(text_lower, final_signals)

out = {
    "continue": True,
    "suppressOutput": True,
    "hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit",
        "additionalContext": suggestion_text
    }
}
print(json.dumps(out, ensure_ascii=False))
PYEOF
