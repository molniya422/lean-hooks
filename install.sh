#!/usr/bin/env bash
# lean-hooks installer — copies templates to Claude Code config directory
set -euo pipefail

TARGET="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SOURCE="$(cd "$(dirname "$0")" && pwd)"

echo "=== lean-hooks Installer ==="
echo "Target: $TARGET"
echo ""

# Create directories
mkdir -p "$TARGET/harness"
mkdir -p "$TARGET/skill-feedback"
mkdir -p "$TARGET/multiagent-feedback"
mkdir -p "$TARGET/rules"
mkdir -p "$TARGET/memory"
mkdir -p "$TARGET/projects"
mkdir -p "$TARGET/data"

# Copy harness scripts
echo "[1/4] Installing harness scripts..."
cp "$SOURCE/harness/"*.sh "$TARGET/harness/"
cp "$SOURCE/harness/"*.py "$TARGET/harness/"
chmod +x "$TARGET/harness/"*.sh 2>/dev/null || true

# Copy templates
echo "[2/4] Installing templates..."
cp "$SOURCE/templates/skill-feedback/"*.json "$TARGET/skill-feedback/" 2>/dev/null || true
cp "$SOURCE/templates/skill-feedback/"*.md "$TARGET/skill-feedback/" 2>/dev/null || true
cp "$SOURCE/templates/multiagent-feedback/"*.json "$TARGET/multiagent-feedback/" 2>/dev/null || true
cp "$SOURCE/templates/multiagent-feedback/"*.md "$TARGET/multiagent-feedback/" 2>/dev/null || true
cp "$SOURCE/templates/rules/"*.md "$TARGET/rules/" 2>/dev/null || true
cp "$SOURCE/templates/memory/"*.md "$TARGET/memory/" 2>/dev/null || true

# Copy settings template (don't overwrite existing)
echo "[3/4] Setting up config files..."
if [ ! -f "$TARGET/settings.json" ]; then
    cp "$SOURCE/settings.template.json" "$TARGET/settings.json"
    echo "  Created settings.json from template"
else
    echo "  settings.json already exists — merge hooks manually from settings.template.json"
fi

if [ ! -f "$TARGET/CLAUDE.md" ]; then
    cp "$SOURCE/CLAUDE.md.template" "$TARGET/CLAUDE.md"
    echo "  Created CLAUDE.md from template"
else
    echo "  CLAUDE.md already exists — merge rules manually from CLAUDE.md.template"
fi

# Post-install check
echo "[4/4] Verifying..."
PY=""
if command -v python3 &>/dev/null; then
    PY="python3"
elif command -v python &>/dev/null; then
    PY="python"
fi

if [ -n "$PY" ]; then
    echo "  Python found: $($PY --version 2>&1)"
else
    echo "  WARNING: Python not found. Set HARNESS_PYTHON=/path/to/python"
fi

echo ""
echo "=== Installation complete ==="
echo "Next steps:"
echo "  1. Review $TARGET/settings.json — ensure hooks match your setup"
echo "  2. Set HARNESS_PYTHON if Python is in a non-standard location"
echo "  3. Restart Claude Code"
echo ""
echo "To disable hooks temporarily:"
echo "  export DISABLED_HOOKS=\"multiagent-detect\""
