#!/usr/bin/env bash
# claude-ecosystem harness — health check
# Validates all systems. Run manually or via SessionStart hook.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# -- Paths are all set by env.sh; just validate them --
MEM_DB="$HARNESS_ROOT/data/claude-mem/claude-mem.db"
AGENT_BROWSER_WRAPPER="$HARNESS_ROOT/tools/agent-browser.sh"

PASS=0; FAIL=0; WARN=0

green()  { printf '\033[32m  PASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
red()    { printf '\033[31m  FAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
yellow() { printf '\033[33m  WARN\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

section "=== Health Check: claude-ecosystem ==="
echo ""

# 1. Memory System
echo "[1] Memory System (CONFIG=$CONFIG_DIR)"
if [ -d "$MEMORY_DIR" ]; then green "memory/ directory exists"; else red "memory/ directory missing: $MEMORY_DIR"; fi
if [ -f "$MEMORY_DIR/MEMORY.md" ]; then
  entries=$(grep -c '^\-\ \[' "$MEMORY_DIR/MEMORY.md" 2>/dev/null || echo 0)
  green "MEMORY.md ($entries entries)"
else
  red "MEMORY.md missing"
fi
echo ""

# 2. TrainingLoop Feedback (v2.1 unified)
echo "[2] TrainingLoop Feedback (LOOP_DIR=$LOOP_DIR)"
if [ -d "$LOOP_DIR" ]; then green "training-loop/ directory exists"; else red "training-loop/ directory missing: $LOOP_DIR"; fi
if [ -f "$LOOP_DIR/feedback.md" ]; then green "feedback.md exists"; else red "feedback.md missing"; fi
if [ -f "$LOOP_DIR/meta.json" ]; then
  version=$("$PY" -c "import json; d=json.load(open('$LOOP_DIR/meta.json',encoding='utf-8')); print(d.get('version','v1'))" 2>/dev/null || echo v1)
  green "meta.json exists ($version)"
else
  yellow "meta.json missing (will be created on first Stop hook)"
fi
if [ -f "$LOOP_DIR/metrics-design.md" ]; then green "metrics-design.md exists"; else yellow "metrics-design.md missing"; fi
if [ -f "$LOOP_DIR/adaptive-threshold.py" ]; then green "adaptive-threshold.py exists"; else yellow "adaptive-threshold.py missing"; fi
echo ""

# 3. CLAUDE.md Section 6
echo "[3] CLAUDE.md Section 6"
if [ -f "$CLAUDE_MD" ] && grep -q "Automatic Memory" "$CLAUDE_MD" 2>/dev/null; then
  green "Section 6 present"
else
  red "Section 6 missing or CLAUDE.md not found"
fi
echo ""

# 4. claude-mem Database
echo "[4] claude-mem Database"
if [ -f "$MEM_DB" ]; then
  size=$(stat -c%s "$MEM_DB" 2>/dev/null || echo 0)
  green "database exists (${size} bytes)"
else
  red "database missing: $MEM_DB"
fi
echo ""

# 5. Harness scripts
#    Core hooks (legacy v1)
echo "[5] Harness Scripts"
for s in health-check.sh training-collect.sh post-task-detect.sh session-start-inject.sh multiagent-detect.sh security-audit.sh; do
  if [ -x "$HARNESS_DIR/$s" ]; then green "$s — executable"
  elif [ -f "$HARNESS_DIR/$s" ]; then yellow "$s — exists but not executable"
  else red "$s — missing"
  fi
done
#    New v2 modules
for s in error-handler.sh plugin-loader.sh; do
  if [ -f "$HARNESS_DIR/$s" ]; then green "$s — present"
  else yellow "$s — missing (optional but recommended)"
  fi
done
#    Python modules
for py in data-lifecycle.py weighted-scoring.py stats.py test_all.py auto-summary.py; do
  if [ -f "$HARNESS_DIR/$py" ]; then green "$py — present"
  else yellow "$py — missing"
  fi
done
echo ""

# 6. lean-hooks infrastructure
echo "[6] lean-hooks Infrastructure"
if [ -f "$HARNESS_ROOT/lean-hooks.toml" ]; then green "lean-hooks.toml — present"
else yellow "lean-hooks.toml — missing (defaults apply)"; fi
if [ -d "$HARNESS_ROOT/hooks" ]; then
    count=$(find "$HARNESS_ROOT/hooks" -maxdepth 1 -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')
    green "hooks/ directory — $count plugin(s) registered"
else yellow "hooks/ directory — missing (plugin system inactive)"; fi
if [ -d "$HARNESS_ROOT/archive" ]; then green "archive/ directory — present (data lifecycle ready)"
else yellow "archive/ directory — missing (data lifecycle inactive)"; fi
echo ""

# 7. Web Access
echo "[7] Web Access"
if [ -f "$AGENT_BROWSER_BIN" ]; then
  ab_ver=$("$AGENT_BROWSER_BIN" --version 2>/dev/null || echo "unknown")
  green "agent-browser binary — $ab_ver"
else
  red "agent-browser binary missing: $AGENT_BROWSER_BIN"
fi

if [ -f "$AGENT_BROWSER_WRAPPER" ]; then green "agent-browser wrapper exists"; else red "agent-browser wrapper missing: $AGENT_BROWSER_WRAPPER"; fi

if [ -f "$CHROME_EXE" ]; then green "Chromium — $CHROME_EXE"; else red "Chromium missing: $CHROME_EXE"; fi
echo ""

# 8. Metrics Engine (v2.1)
echo "[8] Metrics Engine"
if [ -f "$HARNESS_DIR/training-collect.py" ]; then
  ver=$("$PY" "$HARNESS_DIR/training-collect.py" --help 2>/dev/null | head -1 || echo unknown)
  green "training-collect.py — $ver"
else
  yellow "training-collect.py missing"
fi
echo ""

echo "---"
printf "Results: \033[32m%d pass\033[0m, \033[33m%d warn\033[0m, \033[31m%d fail\033[0m\n" "$PASS" "$WARN" "$FAIL"

if [ "$FAIL" -gt 0 ]; then exit 1; fi

# Emit JSON with suppressOutput so dynamic stdout (counts, sizes, versions)
# doesn't enter AI context as additionalContext (breaks prompt caching)
echo '{"continue":true,"suppressOutput":true}'
