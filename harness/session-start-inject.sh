#!/usr/bin/env bash
# SessionStart injector — v2.2 (ML metrics + signal-count EMA)
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

# --- Collect plugin output before exec (to inject into context) ---
# Disabled to keep the hook output prefix stable for prompt caching.
plugin_context=""

exec "$PY" - "$META" "$MEMORY_DIR" "$plugin_context" "$HARNESS_ROOT" <<'PYEOF'
import json, os, re, sys, time

meta_path = sys.argv[1]
memory_dir = sys.argv[2]
plugin_context = ""
harness_root = sys.argv[4] if len(sys.argv) > 4 else os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

# --- Reset multiagent session state on every SessionStart ---
STATE_FILE = os.path.join(harness_root, "data", "multiagent_session_state.json")
try:
    if os.path.exists(STATE_FILE):
        os.remove(STATE_FILE)
except Exception:
    pass

def build_skill_attention_table():
    """Query DB for skill attention weights, format for injection."""
    db_path = os.path.join(harness_root, "data", "claude-mem", "claude-mem.db")
    if not os.path.isfile(db_path):
        return ""
    try:
        import sqlite3
        conn = sqlite3.connect(db_path)
        rows = conn.execute(
            "SELECT skill_name, attention_weight, trigger_count, fp_count, fn_count "
            "FROM skill_attention_weights "
            "WHERE trigger_count > 0 OR fp_count > 0 OR fn_count > 0 "
            "ORDER BY attention_weight DESC LIMIT 10"
        ).fetchall()
        conn.close()
        if not rows:
            return ""
        lines = ["  [SkillAttention] Tuned skills (feedback-adjusted):"]
        for name, weight, triggers, fps, fns in rows:
            flag = " [SUPPRESSED]" if weight < 0.7 else (" [BOOSTED]" if weight > 1.1 else "")
            lines.append(
                f"  {name}: attn={weight:.2f}{flag} (t={triggers},fp={fps},fn={fns})"
            )
        return "\n".join(lines) + "\n"
    except Exception:
        return ""

def load_meta():
    try:
        with open(meta_path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

def build_memory_block():
    index = os.path.join(memory_dir, "MEMORY.md")
    if os.path.isfile(index):
        return "  Read MEMORY.md for full index."
    return "  (no memory files found)"

def build_memory_health():
    """Query DB for memory evolution health metrics."""
    db_path = os.path.join(harness_root, "data", "claude-mem", "claude-mem.db")
    if not os.path.isfile(db_path):
        return build_memory_block()

    try:
        import sqlite3
        conn = sqlite3.connect(db_path)
        now_epoch = int(time.time())

        total = conn.execute("SELECT COUNT(*) FROM observations").fetchone()[0]
        active = conn.execute(
            "SELECT COUNT(*) FROM observations WHERE invalidated_at_epoch IS NULL "
            "AND (expires_at_epoch IS NULL OR expires_at_epoch > ?)",
            (now_epoch,),
        ).fetchone()[0]
        invalidated = conn.execute(
            "SELECT COUNT(*) FROM observations WHERE invalidated_at_epoch IS NOT NULL"
        ).fetchone()[0]
        expired = conn.execute(
            "SELECT COUNT(*) FROM observations WHERE expires_at_epoch IS NOT NULL AND expires_at_epoch <= ?",
            (now_epoch,),
        ).fetchone()[0]
        avg_q = conn.execute(
            "SELECT AVG(quality_score) FROM observations WHERE invalidated_at_epoch IS NULL"
        ).fetchone()[0] or 0.0
        high_rel = conn.execute(
            "SELECT COUNT(*) FROM observations WHERE relevance_count > 5"
        ).fetchone()[0]
        chains = conn.execute(
            "SELECT COUNT(*) FROM observations WHERE supersedes_id IS NOT NULL"
        ).fetchone()[0]

        conn.close()

        index_note = ""
        idx_path = os.path.join(memory_dir, "MEMORY.md")
        if os.path.isfile(idx_path):
            index_note = "\n  Read MEMORY.md for full Tier 2 index."

        return (
            f"  Observations: {total} total, {active} active, {invalidated} invalidated, {expired} expired\n"
            f"  Avg quality: {avg_q:.2f} | High-relevance (>5 accesses): {high_rel} | Chain links: {chains}"
            f"{index_note}\n"
            f"  Run `python config/harness/data-lifecycle.py --dry-run` to preview cleanup."
        )
    except Exception:
        return build_memory_block()

met = load_meta()
reminders = []
updated = {}

# --- Injection 1: MANDATORY startup ---
mem_block = build_memory_health()
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
    "  [SkillAttention] Semantic layer active — if [SkillAttention] matches appear\n"
    "  in UserPromptSubmit context, prefer those over keyword guessing.\n"
    f"{build_skill_attention_table()}\n"
    "These steps are NOT optional. Skipping them is the #1 cause of repeated mistakes."
)
reminders.append(startup)

# --- Injection 2: v2.2 EMA-based threshold alerts ---
if met.get("version") in ("2.1", "2.2"):
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
            # cold start: use point metrics (respect has_data)
            has_data = metrics.get("has_data", True)
            f1 = metrics.get("f1") if has_data else None
        if f1 < f1_target:
            p = ema.get("precision") or metrics.get("precision", 0)
            r = ema.get("recall") or metrics.get("recall", 0)
            alerts.append(
                f"[{label}] F1 below target ({f1_target}) — EMA(P/R below threshold)"
            )
    if alerts:
        reminders.append(
            "[TrainingLoop] v2.2 EMA 阈值告警 (F1 低于目标):\n"
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

# --- Injection 5: Project type detection (terminal only, not injected into AI context) ---
root = os.getcwd()
detected = []
if os.path.isfile(os.path.join(root, "Cargo.toml")):
    detected.append("Rust (Cargo.toml)")
if os.path.isfile(os.path.join(root, "package.json")):
    detected.append("TypeScript/JavaScript (package.json)")
if os.path.isfile(os.path.join(root, "pyproject.toml")) or os.path.isfile(os.path.join(root, "requirements.txt")):
    detected.append("Python (pyproject.toml/requirements.txt)")
# Project type detection removed from injection to keep prefix stable for caching

# --- Injection 6: Plugin outputs ---
if plugin_context.strip():
    reminders.append(
        "[Plugin Output]\n" + plugin_context.strip()
    )

# --- Injection 7: Loop failure alerts ---
failure_report = os.path.join(harness_root, "config", "loop-engineering", "failure-report.json")
if os.path.isfile(failure_report):
    try:
        with open(failure_report, encoding="utf-8") as f:
            failures = json.load(f)
        critical = [f for f in failures.get("failures", []) if f.get("severity") == "critical"]
        if critical:
            alerts = [f"  {c['mode']}: {c['pattern']} — {c['detail']}" for c in critical[:3]]
            reminders.append(
                "[LoopFailure] CRITICAL failure(s) detected:\n"
                + "\n".join(alerts)
                + "\n  Run: loop-failure-detector.py report  for details"
            )
    except Exception:
        pass

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
