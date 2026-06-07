#!/usr/bin/env bash
# SessionStart injector — heavy mode v5
# Injections:
#   1. MANDATORY startup sequence: search claude-mem-lite + memory index + skill pattern match
#   2. SkillOpt threshold alert (lowered to 3 for faster cycle)
#   3. Backfill hint (one-time)
# Uses Anaconda python (MINGW64 python3 stub exits 49).
set -euo pipefail

export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

PY="D:/jiqixuexi/anaconda/python.exe"
META="D:/claude-ecosystem/config/skill-feedback/meta.json"
TOOLCALL_META="D:/claude-ecosystem/config/toolcall-feedback/meta.json"
MEMORY_DIR="D:/claude-ecosystem/config/projects/D--claude-ecosystem/memory"

if [ ! -f "$META" ]; then
  echo '{"continue":true,"suppressOutput":true}'
  exit 0
fi

META_PATH="$META" MEMORY_DIR="$MEMORY_DIR" TOOLCALL_META="$TOOLCALL_META" "$PY" - <<'PYEOF'
import json, os, re, sys

# -- Read meta --
meta_path = os.environ["META_PATH"]
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

# Parse frontmatter from each memory file to get descriptions
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

# Build injection
memory_list_lines = []
for name, filename, desc in memory_details:
    memory_list_lines.append(f"  - {name} ({filename}): {desc}")

memory_block = "\n".join(memory_list_lines) if memory_list_lines else "  (no memory files found)"

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

# -- Injection 2a: SkillOpt threshold (lowered to 3 for faster cycle) --
misses = d.get("misses", 0)
fps = d.get("false_positives", 0)
total = d.get("total_feedback_entries", misses + fps)
threshold = d.get("threshold", 3)
last_opt = d.get("last_optimized", "unknown")

if total >= threshold:
    reminders.append(
        f"[SkillOpt Threshold] {total}/{threshold} (m={misses} fp={fps}), "
        f"last optimized {last_opt}. Remind user to optimize CLAUDE.md Section 6 triggers."
    )

# -- Injection 2b: MultiAgentOpt threshold --
MULTIAGENT_META = "D:/claude-ecosystem/config/multiagent-feedback/meta.json"
try:
    ma = json.loads(open(MULTIAGENT_META, encoding="utf-8").read())
    ma_misses = ma.get("misses", 0)
    ma_fps = ma.get("false_positives", 0)
    ma_total = ma.get("total_feedback_entries", ma_misses + ma_fps)
    ma_threshold = ma.get("threshold", 3)
    ma_last_opt = ma.get("last_optimized", "unknown")
    if ma_total >= ma_threshold:
        reminders.append(
            f"[MultiAgentOpt Threshold] {ma_total}/{ma_threshold} (m={ma_misses} fp={ma_fps}), "
            f"last optimized {ma_last_opt}. Remind user to optimize multiagent-detect scoring rules."
        )
except Exception:
    pass

# -- Injection 2c: ToolCallOpt threshold --
TOOLCALL_META = os.environ.get("TOOLCALL_META", "D:/claude-ecosystem/config/toolcall-feedback/meta.json")
try:
    tc = json.loads(open(TOOLCALL_META, encoding="utf-8").read())
    tc_obs = tc.get("observations", 0)
    tc_threshold = tc.get("threshold", 3)
    tc_last_opt = tc.get("last_optimized", "unknown")
    if tc_obs >= tc_threshold:
        reminders.append(
            f"[ToolCallOpt Threshold] {tc_obs}/{tc_threshold} observations, "
            f"last optimized {tc_last_opt}. Review tool call patterns in toolcall-feedback/feedback.md."
        )
except Exception:
    pass

# -- Injection 3: Backfill hint (one-time) --
backfill_shown = d.get("backfill_hint_shown", False)
if not backfill_shown:
    reminders.append(
        "[Backfill Hint] Use /summarize --backfill or mem-search-lite to "
        "catch up on past sessions lacking memory. One-time notice."
    )
    updated["backfill_hint_shown"] = True

# -- Injection 4: Hooks control hint + project type detection --

# Hooks control
reminders.append(
    "[Hooks Control] Temporarily disable hooks via: "
    'export DISABLED_HOOKS="multiagent-detect" (comma-separated, e.g. "multiagent-detect,post-task-detect")'
)

# Project type detection
root = os.getcwd()
detected = []
if os.path.isfile(os.path.join(root, "Cargo.toml")):
    detected.append("Rust (Cargo.toml)")
if os.path.isfile(os.path.join(root, "package.json")):
    detected.append("TypeScript/JavaScript (package.json)")
if os.path.isfile(os.path.join(root, "pyproject.toml")) or os.path.isfile(os.path.join(root, "requirements.txt")):
    detected.append("Python (pyproject.toml/requirements.txt)")
if detected:
    project_hint = ", ".join(detected)
    reminders.append(
        f"[Project Type] Detected: {project_hint}. "
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
