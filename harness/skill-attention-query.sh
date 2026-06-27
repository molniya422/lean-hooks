#!/usr/bin/env bash
# Skill Attention Layer — UserPromptSubmit hook
# Embeds user prompt, retrieves top-K skills via semantic similarity,
# injects ranked skill suggestions into AI context.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

export PYTHONIOENCODING=utf-8
export PYTHONUTF8=1

# Use the Python interpreter detected by env.sh ($PY) — it must have
# onnxruntime + tokenizers installed.  Alternatively, set
# SKILL_ATTENTION_PYTHON to a specific interpreter.
SKILL_ATTN_PY="${SKILL_ATTENTION_PYTHON:-$PY}"
if ! "$SKILL_ATTN_PY" --version &>/dev/null; then
    echo '{"continue":true,"suppressOutput":true}'
    exit 0
fi

# Skip if skill-attention is disabled
if [ -n "${DISABLED_HOOKS:-}" ] && echo "$DISABLED_HOOKS" | grep -q "skill-attention"; then
    echo '{"continue":true,"suppressOutput":true}'
    exit 0
fi

# Skip if MODEL_DIR not configured
if [ -z "${SKILL_ATTENTION_MODEL_DIR:-}" ]; then
    echo '{"continue":true,"suppressOutput":true}'
    exit 0
fi

# Skip if index not built yet
INDEX_FLAG="$HARNESS_ROOT/data/skill-attention-index.flag"
if [ ! -f "$INDEX_FLAG" ]; then
    echo '{"continue":true,"suppressOutput":true}'
    exit 0
fi

# Read user prompt from stdin (Claude Code passes JSON with prompt field)
INPUT=$(cat)

# Extract prompt text from JSON input
PROMPT=$("$SKILL_ATTN_PY" -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print(data.get('prompt', data.get('user_prompt', '')))
except Exception:
    print('')
" <<< "$INPUT" 2>/dev/null || echo "")

# Skip empty prompts or very short ones
if [ -z "$PROMPT" ] || [ ${#PROMPT} -lt 5 ]; then
    echo '{"continue":true,"suppressOutput":true}'
    exit 0
fi

# Run query — output hook JSON format
"$SKILL_ATTN_PY" "$SCRIPT_DIR/skill-attention.py" query --prompt "$PROMPT" --hook 2>/dev/null || \
    echo '{"continue":true,"suppressOutput":true}'
