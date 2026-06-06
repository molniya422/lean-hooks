# lean-hooks

A lightweight, zero-dependency automation harness for Claude Code — hooks, memory, skill optimization, and multi-agent detection.

**7 scripts. Zero dependencies. Instant setup.**

## What It Does

| Hook | Script | Purpose |
|---|---|---|
| SessionStart | `health-check.sh` | Validates harness integrity (memory, feedback, DB, scripts) |
| SessionStart | `session-start-inject.sh` | Injects live memory index + mandatory 3-step startup checklist |
| SessionStart | `security-audit.sh` | Lightweight security audit (.env, API keys, permissions) |
| UserPromptSubmit | `post-task-detect.sh` | Detects completion signals → injects write reminders |
| UserPromptSubmit | `multiagent-detect.sh` | Two-phase heuristic: suggests parallel agent dispatch for complex tasks |
| Stop | `skillopt-collect.sh` | Parses feedback.md → syncs meta.json → emits threshold alerts |
| (manual) | `auto-summary.py` | Writes 1-line session log to SQLite (searchable via claude-mem-lite) |

## Quick Start

```bash
# Clone
git clone https://github.com/YOUR_USER/lean-hooks.git
cd lean-hooks

# Install (copies templates to your Claude config directory)
./install.sh
# Windows: .\install.ps1

# Set Python path if not auto-detected
export HARNESS_PYTHON=/path/to/python

# Done! Restart Claude Code.
```

## Requirements

- Claude Code CLI v2.1+
- Python 3.8+ (for inline scripting in hooks)
- Bash (Linux/macOS/WSL) or Git Bash (Windows)

## Architecture

```
~/.claude/
├── settings.json      ← hooks wired here (see settings.template.json)
├── CLAUDE.md          ← behavioral rules (see CLAUDE.md.template)
├── harness/           ← all hook scripts
├── skill-feedback/    ← SkillOpt feedback loop (feedback.md + meta.json)
├── multiagent-feedback/ ← MultiAgentOpt feedback loop
├── memory/            ← MEMORY.md + per-project memory files
├── projects/          ← per-project auto-generated content
└── data/              ← SQLite DB for session logs
```

## Multi-Agent Detection

`multiagent-detect.sh` uses a two-phase heuristic scoring system:

- **Phase 1**: Fast keyword/pattern matching (filters ~95% of chat, zero API cost)
- **Phase 2**: Structural analysis (task verb count, file references, tech boundaries)
- **Trigger threshold**: Conservative — false negatives preferred over false positives
- **LLM classifier interface**: Commented placeholder for future lightweight LLM integration

## Feedback Loops

### SkillOpt
When a skill trigger misses or fires incorrectly, say "skill miss" or "skill false positive".
Threshold: 3 entries → SessionStart reminds you to optimize trigger rules.

### MultiAgentOpt
Same pattern for multi-agent detection accuracy.
Say "multiagent miss" or "multiagent false positive" to record feedback.

## Customization

```bash
# Temporarily disable specific hooks
export DISABLED_HOOKS="multiagent-detect,post-task-detect"

# Override Python path
export HARNESS_PYTHON=/usr/bin/python3.11

# Override harness root
export HARNESS_ROOT=~/.claude
```

## Acknowledgements

lean-hooks draws inspiration and design patterns from:

- **[Everything Claude Code (ECC)](https://github.com/affaan-m/ECC)** — The pioneering full-stack Claude Code plugin ecosystem (209k+ stars). ECC demonstrated what's possible with Claude Code automation at scale: multi-agent orchestration, continuous learning, security scanning, and a comprehensive plugin marketplace. lean-hooks is the "minimal core" alternative — focused on the 20% of functionality that delivers 80% of the value, with zero external dependencies.

- **Claude Code Hooks System** — Anthropic's official hook infrastructure (`SessionStart`, `UserPromptSubmit`, `Stop`) that makes this project possible.

- **Vibe Coding** — This entire project was built through vibe coding: the author provided the ideas, architecture, and direction; Claude Code (the AI) wrote every line of code, handled all implementation details, fixed bugs, and iterated on feedback. The author's role was purely conceptual — defining requirements, providing feedback, and steering the design.

## License

MIT
