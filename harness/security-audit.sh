#!/usr/bin/env bash
# Security audit — SessionStart hook (Lightweight)
# Inspired by ECC AgentShield but stripped to essentials (<100ms).
# Checks: .env exposure, plaintext API keys, harness permissions.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

CLAUDE_MD="$CONFIG_DIR/CLAUDE.md"
SETTINGS_JSON="$CONFIG_DIR/settings.json"
CWD=$(pwd)

PASS=0
WARN=0
FAIL=0

green()  { printf '\033[32m  PASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
red()    { printf '\033[31m  FAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
yellow() { printf '\033[33m  WARN\033[0m %s\n' "$*"; WARN=$((WARN+1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$*"; }

section "=== Security Audit ==="
echo ""

# 1. .env file check
ENV_ISSUES=0
if [ -f "$CWD/.env" ]; then
    if [ -f "$CWD/.gitignore" ] && grep -q '\.env' "$CWD/.gitignore" 2>/dev/null; then
        green ".env present but ignored by git"
    else
        red ".env detected but NOT in .gitignore — risk of accidental commit"
        ENV_ISSUES=$((ENV_ISSUES+1))
    fi
fi
if [ "$ENV_ISSUES" -eq 0 ] && [ ! -f "$CWD/.env" ]; then
    green "No .env file detected"
fi

echo ""

# 2. Plaintext API key check
KEY_ISSUES=0
if [ -f "$SETTINGS_JSON" ]; then
    if grep -oP 'sk-[a-zA-Z0-9]{20,}' "$SETTINGS_JSON" 2>/dev/null >/dev/null; then
        red "settings.json contains plaintext API key pattern"
        KEY_ISSUES=$((KEY_ISSUES+1))
    fi
fi
if [ -f "$CLAUDE_MD" ]; then
    if grep -oP 'sk-[a-zA-Z0-9]{20,}' "$CLAUDE_MD" 2>/dev/null >/dev/null; then
        red "CLAUDE.md contains plaintext API key pattern"
        KEY_ISSUES=$((KEY_ISSUES+1))
    fi
fi
if [ "$KEY_ISSUES" -eq 0 ]; then
    green "No plaintext API keys in config files"
fi

echo ""

# 3. Harness script permissions
for s in health-check.sh training-collect.sh post-task-detect.sh session-start-inject.sh multiagent-detect.sh security-audit.sh; do
    f="$HARNESS_DIR/$s"
    if [ -x "$f" ]; then
        PASS=$((PASS+1))
    elif [ -f "$f" ]; then
        yellow "$s exists but not executable"
    else
        red "$s missing"
    fi
done

echo ""
echo "---"
printf "Results: \033[32m%d pass\033[0m, \033[33m%d warn\033[0m, \033[31m%d fail\033[0m\n" "$PASS" "$WARN" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
