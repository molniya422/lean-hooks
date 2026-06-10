# lean-hooks

> A lightweight, zero-dependency automation harness for Claude Code — hooks, memory, skill optimization, and multi-agent detection. With **timeout-safe error handling**, **plugin system**, **stats CLI**, **weighted scoring**, and **data lifecycle management**.

**7 hook scripts + 7 utility modules. Zero external dependencies. Single-command install.**

---

## What It Is

Claude Code's hook system lets you run scripts at lifecycle events (`SessionStart`, `UserPromptSubmit`, `Stop`). lean-hooks wires those events into a complete automation framework:

| Lifecycle | What Runs | Purpose |
|---|---|---|
| Session Start | `health-check.sh` | Validates harness integrity |
| | `security-audit.sh` | Scans for .env leaks, plaintext API keys |
| | `session-start-inject.sh` | Injects memory index + startup checklist |
| On Each Prompt | `post-task-detect.sh` | Detects completion keywords → triggers write/summary |
| | `multiagent-detect.sh` | Two-phase heuristic → suggests parallel agent dispatch |
| On Stop | `training-collect.sh` | Syncs feedback counters with EMA/F1 metrics |
| Manual | `auto-summary.py` | Writes 1-line session log to SQLite |

### Utility Modules

| Module | What It Does |
|---|---|
| `error-handler.sh` | `timeout_wrap` + `error_log` + `safe_run` — every hook protected with timeout, failures captured in `ERRORS.md` without crashing the session |
| `plugin-loader.sh` | Auto-discovers `hooks/*.sh` — drop-in plugin system with priority ordering |
| `data-lifecycle.py` | Rotates `MEMORY.md` (>64KB), archives old sessions (>90 days), prunes `ERRORS.md` (>1MB) |
| `weighted-scoring.py` | Time-decay weighted F1, trend analysis, confidence scoring, auto-tuning recommendations |
| `stats.py` | CLI for querying session counts, hook errors, skill/multiagent metrics, weekly trends |
| `test_all.py` | 7-group integration test suite covering every module |

---

## Quick Start

```bash
git clone https://github.com/naihenh/lean-hooks.git
cd lean-hooks

# Linux / macOS / WSL
./install.sh

# Windows PowerShell
.\install.ps1

# Done! Restart Claude Code.
```

---

## Architecture

```
~/.claude/
├── lean-hooks.toml          ← granular per-hook config (new)
├── settings.json            ← hooks wired here
├── CLAUDE.md                ← behavioral rules
├── harness/                 ← all scripts
│   ├── env.sh               ← shared Python / root detection
│   ├── error-handler.sh     ← timeout + error logging
│   ├── plugin-loader.sh     ← plugin auto-registration
│   ├── health-check.sh
│   ├── security-audit.sh
│   ├── session-start-inject.sh
│   ├── post-task-detect.sh
│   ├── multiagent-detect.sh
│   ├── training-collect.sh / training-collect.py
│   ├── auto-summary.py
│   ├── data-lifecycle.py    ← rotation / archiving
│   ├── weighted-scoring.py  ← enhanced F1 scoring
│   ├── stats.py             ← query CLI
│   └── test_all.py          ← integration tests
├── hooks/                   ← drop-in plugin directory
│   └── SessionStart_10--custom-health.sh
├── training-loop/           ← unified feedback (SkillOpt + MultiAgentOpt + ToolCallOpt)
├── memory/                  ← MEMORY.md + per-project files
├── data/                    ← SQLite DB
├── archive/                 ← rotated MEMORY.md + archived sessions
└── ERRORS.md                ← auto-generated error log
```

---

## Key Features

### Error Handling — Non-Blocking by Design

Every hook runs inside `timeout_wrap`. If it times out or crashes, the error is logged to `ERRORS.md` and the session continues uninterrupted:

```
[User Prompt] ──► hook.sh ──► timeout 15s ──► success? ──► continue
                                        └── failure? ──► ERRORS.md ──► continue
```

No hook ever blocks your Claude session.

### lean-hooks.toml — Granular Config

```toml
[[hook]]
name = "multiagent-detect"
events = ["UserPromptSubmit"]
timeout = 15
enabled = true

[project."my-project"]
disabled_hooks = ["multiagent-detect"]

[data_lifecycle]
max_memory_kb = 64
max_session_days = 90
```

Environment variable `DISABLED_HOOKS` still works and takes precedence.

### Multi-Agent Detection — Now with --dry-run

Debug the scoring system without affecting your session:

```bash
echo '{"prompt":"fix auth module and refactor login page"}' \
  | bash harness/multiagent-detect.sh --dry-run

# Output:
# Phase 1 score: 2 (moderate_keyword)
# Phase 2 score: 3 (moderate_keyword, multi_verb, multi_file)
# Decision: NO TRIGGER (< 4)
```

### Plugin System — Drop-In Hooks

Name any script `hooks/<Event>[_<Priority>]--<Name>.sh` and it's auto-registered:

```
hooks/
├── SessionStart_10--custom-health.sh   ← runs first
├── UserPromptSubmit_50--logger.sh      ← medium priority
└── Stop_99--cleanup.sh                 ← last
```

### Stats CLI — Query Everything

```bash
python harness/stats.py                  # dashboard
python harness/stats.py sessions         # session log list
python harness/stats.py hooks            # hook error analysis
python harness/stats.py skills           # SkillOpt metrics
python harness/stats.py multiagent       # MultiAgentOpt metrics
python harness/stats.py trends --json    # machine-readable trends
```

### Data Lifecycle — Auto-Cleanup

| Data | Threshold | Action |
|---|---|---|
| `MEMORY.md` | >64 KB | Rotated to `archive/MEMORY.YYYY-MM-DD.md` |
| Session logs | >90 days | Archived to `archive/session_logs.YYYY-MM-DD.jsonl` |
| `ERRORS.md` | >1 MB | Rotated to `archive/ERRORS.YYYY-MM-DD.md` |

Run manually: `python harness/data-lifecycle.py --dry-run`

### Weighted Scoring — Beyond Raw F1

The TrainingLoop collects feedback across three dimensions. `weighted-scoring.py` enhances raw metrics with:

- **Time decay** — recent observations count more (half-life: 10 sessions)
- **Per-type weights** — correct triggers (+1.0), misses (-0.8), false positives (-0.6)
- **Trend analysis** — improving / declining / fluctuating
- **Confidence** — 0.0 (no data) to 1.0 (high confidence)

```bash
python harness/weighted-scoring.py --recommend
```

---

## Multi-Agent Detection Details

The detection runs a two-phase heuristic on every user prompt:

1. **Phase 1** — Fast keyword/pattern matching. Filters ~95% of chat. Score >= 4 triggers dispatch suggestion.
2. **Phase 2** — Structural analysis (task verbs, file references). Runs only when Phase 1 score lands in [2, 4).

We bias toward **false negatives over false positives** — better to miss a suggestion than to spam irrelevant ones. If the system fires incorrectly, say "multiagent false positive" to record training data.

---

## Feedback Loops

Three training dimensions share one feedback system at `training-loop/`:

```
Observe → Evaluate → Record → Score → Alert → Improve
```

| Dimension | What It Tracks |
|---|---|
| SkillOpt | Skill trigger accuracy (misses / false positives) |
| MultiAgentOpt | Agent dispatch accuracy (misses / false positives) |
| ToolCallOpt | Tool call pattern quality (positive / negative) |

All three write to the same `training-loop/feedback.md`. The `session-start-inject.sh` hook reads the unified `meta.json` and surfaces threshold alerts when F1 drops below 0.75.

---

## Requirements

- Claude Code CLI v2.1+
- Python 3.8+ (for inline Python in hooks)
- Bash (Linux / macOS / WSL) or Git Bash (Windows)

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `HARNESS_PYTHON` | auto-detected | Override Python interpreter path |
| `HARNESS_ROOT` | auto-detected | Override config root directory |
| `DISABLED_HOOKS` | — | Comma-separated hook names to disable |
| `PROJECT_NAME` | auto-detected | Override project name for per-project config |
| `ERRORS_FILE` | `$CONFIG_DIR/ERRORS.md` | Override error log path |

---

## Acknowledgements

lean-hooks draws inspiration from:

- **[Everything Claude Code (ECC)](https://github.com/affaan-m/ECC)** — Hook runtime control (`DISABLED_HOOKS`), security audit patterns, rules layering
- **[LangGraph](https://github.com/langchain-ai/langgraph)** — Stateful agent orchestration, two-phase detection architecture
- **[claude-mem-lite](https://github.com/thedotmack/claude-mem-lite)** — SQLite-backed session log search
- **[CodeGraph](https://github.com/anthropics/codegraph)** — Tree-sitter knowledge graph for structural code queries
- **[superpowers](https://github.com/claude-plugins-official/superpowers)** — Skill system patterns and feedback loop design
- **Claude Code** — The hook infrastructure that makes this project possible

**Vibe Coded**: This entire project was built through vibe coding — ideas and direction from the author, every line written by Claude Code.

## License

MIT