#!/usr/bin/env bash
# claude-ecosystem harness — health check
# Validates all four systems. Run manually or via SessionStart hook.
set -euo pipefail

ECOSYSTEM="D:/claude-ecosystem"
MEMORY_DIR="$ECOSYSTEM/config/projects/D--claude-ecosystem/memory"
FEEDBACK_DIR="$ECOSYSTEM/config/skill-feedback"
CLAUDE_MD="$ECOSYSTEM/config/CLAUDE.md"
MEM_DB="$ECOSYSTEM/data/claude-mem/claude-mem.db"
HARNESS_DIR="$ECOSYSTEM/config/harness"

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
  red "memory/ directory missing: $MEMORY_DIR"
fi

if [ -f "$MEMORY_DIR/MEMORY.md" ]; then
  entries=$(grep -c '^\-\ \[' "$MEMORY_DIR/MEMORY.md" 2>/dev/null || echo 0)
  green "MEMORY.md ($entries entries)"
else
  red "MEMORY.md missing"
fi

echo ""

# 2. SkillOpt Feedback
echo "[2] SkillOpt Feedback"
if [ -f "$FEEDBACK_DIR/feedback.md" ]; then
  green "feedback.md exists"
else
  red "feedback.md missing"
fi

if [ -f "$FEEDBACK_DIR/meta.json" ]; then
  green "meta.json exists"
else
  yellow "meta.json missing (will be created on first Stop hook)"
fi

echo ""

# 3. CLAUDE.md Section 6
echo "[3] CLAUDE.md Section 6"
if grep -q "Automatic Memory" "$CLAUDE_MD" 2>/dev/null; then
  green "Section 6 present"
else
  red "Section 6 missing"
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
