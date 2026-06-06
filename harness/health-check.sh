#!/usr/bin/env bash
# Harness — health check
# Validates all harness systems. Run manually or via SessionStart hook.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

MEMORY_DIR="$HARNESS_ROOT/memory"
FEEDBACK_DIR="$HARNESS_ROOT/skill-feedback"
CLAUDE_MD="$HARNESS_ROOT/CLAUDE.md"
MEM_DB="$HARNESS_ROOT/data/claude-mem.db"
HARNESS_DIR="$HARNESS_ROOT/harness"

PASS=0
FAIL=0
WARN=0

green()  { printf '\033[32m  PASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
red()    { printf '\033[31m  FAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
yellow() { printf '\033[33m  WARN\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

section "=== Health Check: claude-ecosystem ==="
echo ""

# 1. Memory System
echo "[1] Memory System"
if [ -d "$MEMORY_DIR" ]; then
  green "memory/ directory exists"
else
  yellow "memory/ directory not found at $MEMORY_DIR"
fi

if [ -f "$MEMORY_DIR/MEMORY.md" ]; then
  entries=$(grep -c '^\-\ \[' "$MEMORY_DIR/MEMORY.md" 2>/dev/null || echo 0)
  green "MEMORY.md ($entries entries)"
else
  yellow "MEMORY.md not found (will be created on first use)"
fi

echo ""

# 2. SkillOpt Feedback
echo "[2] SkillOpt Feedback"
if [ -f "$FEEDBACK_DIR/feedback.md" ]; then
  green "feedback.md exists"
else
  yellow "feedback.md not found (will be created)"
fi

if [ -f "$FEEDBACK_DIR/meta.json" ]; then
  green "meta.json exists"
else
  yellow "meta.json missing (created on first Stop hook)"
fi

echo ""

# 3. CLAUDE.md Section 6
echo "[3] CLAUDE.md"
if grep -q "Automatic Memory" "$CLAUDE_MD" 2>/dev/null; then
  green "Section 6 present"
else
  yellow "Section 6 not found in CLAUDE.md"
fi

echo ""

# 4. claude-mem Database
echo "[4] claude-mem Database"
if [ -f "$MEM_DB" ]; then
  size=$(stat -c%s "$MEM_DB" 2>/dev/null || echo 0)
  green "database exists (${size} bytes)"
else
  yellow "database not found at $MEM_DB (will be created on first session log)"
fi

echo ""

# 5. Harness Scripts
echo "[5] Harness Scripts"
for s in health-check.sh skillopt-collect.sh post-task-detect.sh session-start-inject.sh multiagent-detect.sh security-audit.sh; do
  if [ -x "$HARNESS_DIR/$s" ]; then
    green "$s — executable"
  elif [ -f "$HARNESS_DIR/$s" ]; then
    yellow "$s — exists but not executable"
  else
    red "$s — missing"
  fi
done

echo ""
echo "---"
printf "Results: \033[32m%d pass\033[0m, \033[33m%d warn\033[0m, \033[31m%d fail\033[0m\n" "$PASS" "$WARN" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
