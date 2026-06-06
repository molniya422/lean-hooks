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

- **[Everything Claude Code (ECC)](https://github.com/affaan-m/ECC)** — The pioneering full-stack Claude Code plugin ecosystem (209k+ stars). ECC demonstrated multi-agent orchestration at scale, security scanning (AgentShield), and continuous learning. lean-hooks adopted ECC's hook runtime control (`DISABLED_HOOKS`), rules layering, and lightweight security audit patterns, then stripped them to their minimal core.

- **[LangGraph](https://github.com/langchain-ai/langgraph)** — LangChain's stateful agent orchestration framework. Its graph-based execution model (State → Node → Edge → Checkpoint → Human-in-the-loop) directly inspired lean-hooks' two-phase multi-agent detection architecture and file-based state protocol.

- **[claude-mem-lite](https://github.com/thedotmack/claude-mem-lite)** — MCP memory search server providing SQLite-backed session log search. lean-hooks' `auto-summary.py` writes directly to claude-mem-lite's `session_logs` table.

- **[CodeGraph](https://github.com/anthropics/codegraph)** — Tree-sitter-parsed knowledge graph MCP server for structural code queries. Referenced in lean-hooks' CLAUDE.md rules for efficient codebase exploration.

- **[Claude Code](https://claude.ai/code)** — Anthropic's AI-powered CLI. The hook infrastructure (`SessionStart`, `UserPromptSubmit`, `Stop`) and plugin system that make this project possible.

- **[superpowers](https://github.com/claude-plugins-official/superpowers)** — The official Claude Code plugin providing skill system patterns that influenced lean-hooks' skill trigger rules and feedback loop design.

- **Vibe Coding** — This entire project was built through vibe coding: the author provided ideas, architecture, and direction; Claude Code wrote every line of code, handled all implementation details, fixed bugs, and iterated on feedback. Zero lines were hand-written by the author.

## License

MIT
