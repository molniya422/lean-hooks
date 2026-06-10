#!/usr/bin/env bash
# SessionStart injector — v2.1 (ML metrics)
#
# Injection Sequence (all use safe_run for timeout+error handling):
#   1. MANDATORY startup sequence: search + memory index + skill match
#   2. Threshold alerts based on EMA F1 / Loss (not raw counts)
#   3. Backfill hint (one-time)
#   4. Hooks control reminder
#   5. Project type detection
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# safe_run wraps this entire script — see error-handler.sh

META="$CONFIG_DIR/training-loop/meta.json"

# Check if hook is disabled
if ! is_hook_enabled "session-start-inject" 2>/dev/null; then
    echo "[lean-hooks] session-start-inject disabled, skipping" >&2
    exit 0
fi

exec "$PY" - "$META" "$MEMORY_DIR" <<'PYEOF'
import json, os, re, sys

meta_path = sys.argv[1]
memory_dir = sys.argv[2]

def load_meta():
    try:
        with open(meta_path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

def build_memory_block():
    index = os.path.join(memory_dir, "MEMORY.md")
    items = []
    if os.path.isfile(index):
        with open(index, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line.startswith("- ["):
                    items.append(line.lstrip("- "))
    details = []
    for item in items:
        m = re.match(r'\[([^\]]+)\]\(([^)]+)\)', item)
        if m:
            name, fname = m.group(1), m.group(2)
            filepath = os.path.join(memory_dir, fname)
            desc = ""
            if os.path.isfile(filepath):
                with open(filepath, encoding="utf-8") as f:
                    content = f.read(1024)
                fm = re.search(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
                if fm:
                    for line in fm.group(1).strip().split('\n'):
                        kv = line.split(':', 1)
                        if len(kv) == 2 and kv[0].strip() == 'description':
                            desc = kv[1].strip()
            details.append((name, fname, desc))
    if not details:
        return "  (no memory files found)"
    return "\n".join(f"  - {n} ({f}): {d}" for n, f, d in details)

met = load_meta()
reminders = []
updated = {}

# --- Injection 1: MANDATORY startup ---
mem_block = build_memory_block()
startup = (
    "[MANDATORY - BLOCKING STARTUP CHECKLIST - DO NOT SKIP]\n"
    "Execute ALL three steps before ANY response or tool call:\n\n"
    "STEP 1 - Search past work:\n"
    '  mcp__mem-search-lite__search(query="<describe this task in 3-5 words>", limit=5)\n'
    "  This prevents repeating work already done.\n\n"
    "STEP 2 - Read relevant memory files. Available:\n"
    f"{mem_block}\n\n"
    "  If this task involves any topic above, Read that file NOW.\n\n"
    "STEP 3 - Match skill by task pattern. Scan the user's request for these signals:\n"
    "  bug/error/fail/crash -> systematic-debugging\n"
    "  implement/add/build/new feature -> test-driven-development\n"
    "  plan/design/before coding -> writing-plans or brainstorming\n"
    "  done/fixed/complete claim -> verification-before-completion\n"
    "  PPT/presentation/slides -> ppt-master\n"
    "  permission/settings/config -> update-config\n"
    "  slow/optimize/perf -> performance\n"
    "  multiple independent tasks -> dispatching-parallel-agents\n"
    "  PR/review/triage -> pr-review or issue-triage\n"
    "  summarize -> summarize\n"
    "  security + review -> security-review\n"
    "  Rust/RTK code -> rtk-tdd or code-simplifier\n"
    "  When in doubt, INVOKE THE SKILL. False positive costs 1s;\n"
    "  a miss costs repeating entire sessions.\n\n"
    "These steps are NOT optional. Skipping them is the #1 cause of repeated mistakes."
)
reminders.append(startup)

# --- Injection 2: v2.1 EMA-based threshold alerts ---
if met.get("version") == "2.1":
    global_cfg = met.get("global", {})
    f1_target = global_cfg.get("f1_target", 0.75)
    dims = met.get("dimensions", {})
    alerts = []
    for key, label in [("skill", "SkillOpt"), ("multiagent", "MultiAgentOpt"), ("toolcall", "ToolCallOpt")]:
        dim = dims.get(key, {})
        ema = dim.get("ema", {})
        metrics = dim.get("metrics", {})
        loss = dim.get("loss", {})
        f1 = ema.get("f1")  # use ema_f1 as primary signal
        if f1 is None:
            # cold start: use point metrics
            f1 = metrics.get("f1", 1.0)
        if f1 < f1_target:
            p = ema.get("precision") or metrics.get("precision", 0)
            r = ema.get("recall") or metrics.get("recall", 0)
            l_core = loss.get("core", 0)
            l_total = loss.get("total", 0)
            counts = dim.get("counts", {})
            tp, fp, fn = counts.get("tp", 0), counts.get("fp", 0), counts.get("fn", 0)
            alerts.append(
                f"[{label}] F1={f1:.3f} (target={f1_target}) "
                f"EMA(P={p:.3f}/R={r:.3f}) L_core={l_core:.3f} "
                f"TP={tp} FP={fp} FN={fn} -> review required"
            )
    if alerts:
        reminders.append(
            "[TrainingLoop] v2.1 EMA 阈值告警 (F1 低于目标):\n"
            + "\n".join(f"  {a}" for a in alerts)
            + "\n\n  反馈入口: training-loop/feedback.md (按 ## SkillOpt / ## MultiAgentOpt / ## ToolCallOpt 分区)\n"
            "  运算器: python training-loop/adaptive-threshold.py --adjust"
        )
elif met:
    # Legacy fallback — simple counts
    misses = met.get("misses", 0)
    fps = met.get("false_positives", 0)
    total = met.get("total_feedback_entries", misses + fps)
    threshold = met.get("threshold", 3)
    if total >= threshold:
        reminders.append(
            f"[SkillOpt] {total}/{threshold} (m={misses} fp={fps}) — review trigger rules"
        )

# --- Injection 3: Backfill hint (one-time) ---
if not met.get("backfill_hint_shown", False):
    reminders.append(
        "[Backfill Hint] Use /summarize --backfill or mem-search-lite to "
        "catch up on past sessions lacking memory. One-time notice."
    )
    updated["backfill_hint_shown"] = True

# --- Injection 4: Hooks control ---
reminders.append(
    "[Hooks Control] Temporarily disable hooks via: "
    'export DISABLED_HOOKS="multiagent-detect" (comma-separated)'
)

# --- Injection 5: Project type detection ---
root = os.getcwd()
detected = []
if os.path.isfile(os.path.join(root, "Cargo.toml")):
    detected.append("Rust (Cargo.toml)")
if os.path.isfile(os.path.join(root, "package.json")):
    detected.append("TypeScript/JavaScript (package.json)")
if os.path.isfile(os.path.join(root, "pyproject.toml")) or os.path.isfile(os.path.join(root, "requirements.txt")):
    detected.append("Python (pyproject.toml/requirements.txt)")
if detected:
    reminders.append(
        f"[Project Type] Detected: {', '.join(detected)}. "
        "Language-specific rules in config/rules/ (framework reserved for v2)."
    )

# Persist backfill hint
if updated and met:
    for k, v in updated.items():
        met[k] = v
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(met, f, indent=2, ensure_ascii=False)

# --- Output ---
if reminders:
    combined = "\n\n".join(reminders)
    out = {
        "continue": True,
        "suppressOutput": True,
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": combined
        }
    }
    print(json.dumps(out, ensure_ascii=False))
else:
    print(json.dumps({"continue": True, "suppressOutput": True}))
PYEOF
