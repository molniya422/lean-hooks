#!/usr/bin/env bash
# SessionStart injector — heavy mode v6 (unified training loop)
# Injections:
#   1. MANDATORY startup sequence: search claude-mem-lite + memory index + skill pattern match
#   2. Unified TrainingLoop threshold alerts (SkillOpt + MultiAgentOpt + ToolCallOpt)
#   3. Backfill hint (one-time)
# Uses Anaconda python (MINGW64 python3 stub exits 49).
set -euo pipefail

export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

PY="D:/jiqixuexi/anaconda/python.exe"
LOOP_META="D:/claude-ecosystem/config/training-loop/meta.json"
LEGACY_SKILL_META="D:/claude-ecosystem/config/skill-feedback/meta.json"
MEMORY_DIR="D:/claude-ecosystem/config/projects/D--claude-ecosystem/memory"

# Use unified meta; fall back to legacy skill-feedback if no training-loop yet
META="${LOOP_META}"
if [ ! -f "$META" ] && [ -f "$LEGACY_SKILL_META" ]; then
  META="$LEGACY_SKILL_META"
fi

if [ ! -f "$META" ]; then
  echo '{"continue":true,"suppressOutput":true}'
  exit 0
fi

META_PATH="$META" MEMORY_DIR="$MEMORY_DIR" LOOP_META="$LOOP_META" "$PY" - <<'PYEOF'
import json, os, re, sys

# -- Read meta (unified or legacy) --
meta_path = os.environ["META_PATH"]
loop_meta = os.environ["LOOP_META"]
try:
    d = json.loads(open(meta_path, encoding="utf-8").read())
except Exception:
    print(json.dumps({"continue": True, "suppressOutput": True}))
    sys.exit(0)

reminders = []
updated = {}

# -- Injection 1: MANDATORY startup with live memory index --
memory_dir = os.environ["MEMORY_DIR"]
mem_index = os.path.join(memory_dir, "MEMORY.md")

memory_items = []
if os.path.isfile(mem_index):
    with open(mem_index, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line.startswith("- ["):
                memory_items.append(line.lstrip("- "))

memory_details = []
for item in memory_items:
    m = re.match(r'\[([^\]]+)\]\(([^)]+)\)', item)
    if m:
        name, filename = m.group(1), m.group(2)
        filepath = os.path.join(memory_dir, filename)
        desc = ""
        if os.path.isfile(filepath):
            with open(filepath, encoding="utf-8") as f:
                content = f.read(1024)
            fm = re.match(r'^---\s*\n(.*?)\n---', content, re.DOTALL)
            if fm:
                for line in fm.group(1).strip().split('\n'):
                    kv = line.split(':', 1)
                    if len(kv) == 2 and kv[0].strip() == 'description':
                        desc = kv[1].strip()
        memory_details.append((name, filename, desc))

memory_block = "\n".join(f"  - {n} ({f}): {d}" for n, f, d in memory_details) if memory_details else "  (no memory files found)"

startup = (
    "[MANDATORY - BLOCKING STARTUP CHECKLIST - DO NOT SKIP]\n"
    "Execute ALL three steps before ANY response or tool call:\n\n"
    "STEP 1 - Search past work:\n"
    '  mcp__mem-search-lite__search(query="<describe this task in 3-5 words>", limit=5)\n'
    "  This prevents repeating work already done.\n\n"
    "STEP 2 - Read relevant memory files. Available:\n"
    f"{memory_block}\n\n"
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

# -- Injection 2: Unified TrainingLoop threshold (all 3 dimensions) --
# Try unified meta first (v2), fall back to legacy format (v1)
dims = None
if os.path.isfile(loop_meta):
    try:
        unified = json.loads(open(loop_meta, encoding="utf-8").read())
        dims = unified.get("dimensions", {})
    except Exception:
        pass

alerts = []

if dims:
    # --- Unified format (v2) ---
    for dim_key, dim_name, fmt in [
        ("skill", "SkillOpt", "trigger rules in CLAUDE.md"),
        ("multiagent", "MultiAgentOpt", "multiagent-detect scoring rules"),
        ("toolcall", "ToolCallOpt", "tool call patterns in training-loop/feedback.md"),
    ]:
        dim = dims.get(dim_key, {})
        total = dim.get("total", dim.get("misses", 0) + dim.get("false_positives", 0) + dim.get("observations", 0))
        threshold = dim.get("threshold", 3)
        if total >= threshold:
            alerts.append(f"[{dim_name}] {total}/{threshold} — review {fmt}")
else:
    # --- Legacy format (v1) — three separate meta files ---
    misses = d.get("misses", 0)
    fps = d.get("false_positives", 0)
    total = d.get("total_feedback_entries", misses + fps)
    threshold = d.get("threshold", 3)
    if total >= threshold:
        alerts.append(f"[SkillOpt] {total}/{threshold} (m={misses} fp={fps}) — review trigger rules")

    ma_meta_path = "D:/claude-ecosystem/config/multiagent-feedback/meta.json"
    try:
        ma = json.loads(open(ma_meta_path, encoding="utf-8").read())
        ma_total = ma.get("total_feedback_entries", ma.get("misses", 0) + ma.get("false_positives", 0))
        if ma_total >= ma.get("threshold", 3):
            alerts.append(f"[MultiAgentOpt] {ma_total}/{ma.get('threshold', 3)} — review scoring rules")
    except Exception:
        pass

    tc_meta_path = "D:/claude-ecosystem/config/toolcall-feedback/meta.json"
    try:
        tc = json.loads(open(tc_meta_path, encoding="utf-8").read())
        tc_obs = tc.get("observations", 0)
        if tc_obs >= tc.get("threshold", 3):
            alerts.append(f"[ToolCallOpt] {tc_obs}/{tc.get('threshold', 3)} — review tool call patterns")
    except Exception:
        pass

if alerts:
    reminders.append("[TrainingLoop] 统一训练系统阈值告警:\n" + "\n".join(f"  {a}" for a in alerts) +
        "\n\n  反馈入口: training-loop/feedback.md (统一文件，按 ## SkillOpt / ## MultiAgentOpt / ## ToolCallOpt 分区)")

# -- Injection 3: Backfill hint (one-time) --
backfill_shown = d.get("backfill_hint_shown", False)
if not backfill_shown:
    reminders.append(
        "[Backfill Hint] Use /summarize --backfill or mem-search-lite to "
        "catch up on past sessions lacking memory. One-time notice."
    )
    updated["backfill_hint_shown"] = True

# -- Injection 4: Hooks control hint + project type detection --
reminders.append(
    "[Hooks Control] Temporarily disable hooks via: "
    'export DISABLED_HOOKS="multiagent-detect" (comma-separated, e.g. "multiagent-detect,post-task-detect")'
)

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

# -- Persist meta updates --
if updated:
    for k, v in updated.items():
        d[k] = v
    with open(meta_path, "w", encoding="utf-8") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)

# -- Output --
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
