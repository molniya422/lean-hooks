# lean-hooks

> A lightweight, zero-dependency automation harness for Claude Code — hooks, memory, skill optimization, multi-agent detection, **and loop engineering**. With timeout-safe error handling, plugin system, stats CLI, weighted scoring, data lifecycle management, **and loop readiness governance**.

**10 hook scripts + 13 utility modules + 6 loop-engineering scripts. Zero external dependencies. Single-command install.**

---

## What It Does

lean-hooks turns Claude Code's hook events (`SessionStart`, `UserPromptSubmit`, `Stop`) into a complete **event-driven context injection framework** with three autonomous feedback loops:

| Loop | What It Governs | Data Store |
|---|---|---|
| **Memory** | Cross-session knowledge persistence | `memory/*.md` + SQLite `session_logs` |
| **TrainingLoop** | Behavioral quality (skill/multiagent/tool accuracy) | `training-loop/feedback.md` + `meta.json` |
| **Loop Engineering** | Automated loop governance (state, budget, failures) | `loop-engineering/states/` + `run-log.jsonl` + `budget.json` |

Hooks don't execute AI operations directly — they **inject context** (reminders, alerts, suggestions) into the AI's working memory. The AI retains judgment over whether to act on them.

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
├── lean-hooks.toml              ← per-hook config (timeout, enabled, events)
├── settings.json                ← hook chain wired here
├── CLAUDE.md                    ← behavioral rules + skill trigger table
│
├── harness/                     ← all scripts (20 files)
│   ├── env.sh                   ← shared Python/root/path detection
│   ├── error-handler.sh         ← timeout + error logging
│   ├── plugin-loader.sh         ← plugin auto-registration
│   │
│   ├── health-check.sh          ← 9-section integrity validation
│   ├── security-audit.sh        ← .env / plaintext key scanner
│   ├── session-start-inject.sh  ← 7-block context injection
│   ├── post-task-detect.sh      ← ~60 completion keyword detector
│   ├── multiagent-detect.sh     ← two-phase parallel agent scorer
│   ├── training-collect.sh/py   ← 3-dimension EMA metrics engine
│   │
│   ├── auto-summary.py          ← Tier1 session log → SQLite
│   ├── data-lifecycle.py        ← MEMORY.md rotation + archival
│   ├── weighted-scoring.py      ← time-decay F1 + trend analysis
│   ├── stats.py                 ← query CLI (sessions, hooks, skills)
│   ├── test_all.py              ← integration test suite
│   │
│   ├── loop-state-manager.py    ← per-pattern state CRUD + rot detection
│   ├── loop-run-logger.py       ← append-only JSONL audit trail
│   ├── loop-budget-tracker.py   ← token budget + 80%/100% kill switch
│   ├── loop-readiness-audit.py  ← 0-100 scoring + L0→L3 levels
│   ├── loop-failure-detector.py ← 9 failure mode runtime detection
│   └── loop-checklist-validator.py ← 10-section design checklist
│
├── hooks/                       ← drop-in plugin directory
│   ├── SessionStart_08--loop-budget-check.sh
│   ├── SessionStart_10--custom-health.sh
│   └── Stop_10--loop-failure-check.sh
│
├── training-loop/               ← SkillOpt + MultiAgentOpt + ToolCallOpt
│   ├── feedback.md               ← unified feedback (3 sections)
│   ├── meta.json                 ← EMA/F1/loss per dimension
│   ├── adaptive-threshold.py     ← standalone threshold optimizer
│   ├── metrics-design.md         ← ML formula documentation
│   └── metrics-schema.json       ← JSON Schema
│
├── loop-engineering/            ← loop governance subsystem
│   ├── LOOP.md                  ← active loops + coordination + rollout plan
│   ├── safety.md                 ← path denylist + auto-merge policy
│   ├── patterns/registry.yaml    ← 7 pattern definitions mapped to skills
│   ├── states/                   ← per-pattern mutable state (7 .json)
│   ├── budget.json               ← daily/weekly token caps + cost per pattern
│   ├── run-log.jsonl             ← append-only execution audit trail
│   ├── failure-report.json       ← current unresolved failure modes
│   └── archive/                  ← pruned run logs
│
├── skills/                      ← task-routing skills
│   ├── loop-engineer/SKILL.md    ← design new loops
│   └── loop-audit/SKILL.md       ← audit loop readiness
│
├── data/                        ← SQLite DB (session_logs)
├── memory/                      ← MEMORY.md + per-project files
└── ERRORS.md                    ← auto-generated error log
```

---

## Hook Chain — What Runs When

| Event | Script | Injects Into AI Context |
|---|---|---|
| **SessionStart** | `health-check.sh` | 9-section integrity report (stdout, not context) |
| | `security-audit.sh` | .env/gitignore warnings |
| | `session-start-inject.sh` | 7 blocks: mandatory 3-step checklist, EMA F1 alerts, backfill hint, hooks control, loop failure alerts |
| | `SessionStart_08--loop-budget-check.sh` | Budget WARNING at 80%, KILL at 100% |
| | `SessionStart_10--custom-health.sh` | Custom project checks |
| **UserPromptSubmit** | `post-task-detect.sh` | Completion reminder (Tier1/Tier2 write + TrainingLoop) when ~60 keywords detected |
| | `multiagent-detect.sh` | Parallel agent suggestion when score ≥4 |
| | `langgraph-router.sh` | LangGraph orchestration (experimental) |
| **Stop** | `training-collect.sh` | Parses feedback → updates meta.json (EMA/F1) |
| | `Stop_10--loop-failure-check.sh` | Scans 9 failure modes → updates failure-report.json |
| **PreToolUse** | (matcher) | Blocks WebFetch/WebSearch (use `mcp__fetch__fetch` instead) |

---

## Three Feedback Loops

### 1. Memory — Cross-Session Knowledge

```
Session ends with substance → auto-summary.py → session_logs (SQLite)
User says "记住/remember"  → memory/*.md + MEMORY.md index
Next SessionStart          → inject memory index hint
AI searches mem-search-lite before repeating work
```

### 2. TrainingLoop — Behavioral Quality

```
AI observes quality issue → writes feedback.md (SkillOpt/MultiAgentOpt/ToolCallOpt)
Session Stop              → training-collect.py computes P/R/F1/EMA/loss
F1 < 0.75 for 3+ sessions → auto-adjusts multiagent threshold
Next SessionStart         → injects F1 alert → AI improves behavior
```

| Dimension | Tracks | Key Metric |
|---|---|---|
| SkillOpt | Skill trigger accuracy | EMA(F1) per skill pattern |
| MultiAgentOpt | Parallel dispatch accuracy | EMA(F1) + threshold auto-tuning |
| ToolCallOpt | Tool call quality | Positive/negative pattern tracking |

Loss function: `L = [(1-P)² + (1-R)²] / [(1-P)+(1-R)+ε] + γ·complexity`

### 3. Loop Engineering — Automated Loop Governance

```
Loop executes                     → run-logger.py records to run-log.jsonl
State changes                     → state-manager.py updates states/<pattern>.json
Tokens consumed                   → budget-tracker.py tracks daily usage
Session Stop                      → failure-detector.py scans 9 failure modes
Next SessionStart                 → budget warnings + critical failure alerts

Readiness scored                  → readiness-audit.py: 0-100 → L0/L1/L2/L3
Design validated                  → checklist-validator.py: 10-section gates
```

**9 Failure Modes Detected at Runtime:**

| Mode | Detection | Severity |
|---|---|---|
| `infinite_fix_loop` | ≥3 consecutive partial outcomes + same pending items | critical |
| `state_rot` | Pending items stale >7d, or consecutive failures ≥3 | high |
| `verifier_theater` | Checker always passes, zero escalations | medium |
| `notification_fatigue` | ≥5 escalations/24h with no human action | medium |
| `token_burn` | Run exceeds 2× expected token cost | high |
| `over_reach` | Actions outside declared tool scope | high |
| `escalation_failure` | Escalated items unresolved >7 days | medium |
| `dead_loop` | No run in 3× cadence period | medium |
| `budget_blowout` | Daily usage >120% despite kill switch | critical |

---

## 7 Loop Patterns

| Pattern | Cadence | Risk | Maker Skill | Checker Skill |
|---|---|---|---|---|
| **Daily Triage** | 1d | low | `issue-triage` | `verification-before-completion` |
| **PR Babysitter** | 5-15m | high | `babysit` | `requesting-code-review` |
| **CI Sweeper** | 5-15m | very high | `systematic-debugging` | `verification-before-completion` |
| **Dependency Sweeper** | 6h-1d | medium | `security-guardian` | `verification-before-completion` |
| **Changelog Drafter** | 1d | low | `repo-recap` | `verification-before-completion` |
| **Post-Merge Cleanup** | 1d-6h | low | `finishing-a-development-branch` | `verification-before-completion` |
| **Issue Triage** | 2h-1d | low | `issue-triage` | `verification-before-completion` |

Each pattern starts at **L1 (report-only)** and advances through L2 (assisted fixes) to L3 (unattended) only after proving reliability.

---

## Loop Readiness Levels

| Level | Score | What It Means |
|---|---|---|
| **L0** | 0-39 | Draft — infrastructure partial, no loops running |
| **L1** | 40-64 | Report-only — can observe and categorize, no auto-actions |
| **L2** | 65-84 | Assisted — maker/checker split + human gates for code changes |
| **L3** | 85-100 | Unattended — full automation with verified safety guardrails |

```bash
python harness/loop-readiness-audit.py --suggest    # full audit + suggestions
python harness/loop-readiness-audit.py --quick       # fast 3-point check
```

---

## Key Features

### Error Handling — Non-Blocking by Design

```
[Hook] ──► timeout_wrap ──► success? ──► continue
                          └── failure? ──► ERRORS.md ──► continue
```

No hook ever blocks your Claude session. All wrapped in `safe_run` with configurable timeouts from `lean-hooks.toml`.

### Multi-Agent Detection — Two-Phase Heuristic

```bash
echo '{"prompt":"fix auth module and refactor login page"}' \
  | bash harness/multiagent-detect.sh --dry-run
# Phase 1 score: 2 (moderate_keyword)
# Phase 2 score: 3 (moderate_keyword, multi_verb, multi_file)
# Decision: NO TRIGGER (< 4)
```

Biases toward false negatives — better to miss a suggestion than spam irrelevant ones. Threshold auto-adjusts when F1 drops below target.

### Plugin System — Drop-In Hooks

```
hooks/
├── SessionStart_08--loop-budget-check.sh   ← budget warnings
├── SessionStart_10--custom-health.sh       ← custom checks
└── Stop_10--loop-failure-check.sh          ← failure scan
```

### Loop Budget — Token Kill Switch

```bash
python harness/loop-budget-tracker.py check --json
# {"daily_percent": 0.0, "status": "ok"}
```

- **80%** → WARNING injected at session start
- **100%** → KILL, all loop executions blocked
- Per-pattern cost tracking in `budget.json`

### Stats CLI — Query Everything

```bash
python harness/stats.py                  # dashboard
python harness/stats.py sessions         # session log list
python harness/stats.py multiagent       # MultiAgentOpt metrics
python harness/stats.py trends --json    # machine-readable trends
```

### Data Lifecycle — Auto-Cleanup

| Data | Threshold | Action |
|---|---|---|
| `MEMORY.md` | >64 KB | Rotated to `archive/` |
| Session logs | >90 days | Archived to `archive/` |
| `ERRORS.md` | >1 MB | Rotated to `archive/` |
| Run log | >90 days | Pruned to `loop-engineering/archive/` |

---

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `HARNESS_PYTHON` | auto-detected | Override Python interpreter path |
| `HARNESS_ROOT` | auto-detected | Override config root directory |
| `DISABLED_HOOKS` | — | Comma-separated hook names to disable |
| `PROJECT_NAME` | auto-detected | Override project name for per-project config |
| `LOOP_BUDGET_EXHAUSTED` | — | Set to `1` to block all loop executions |

---

## Data Flow — One Session Lifecycle

```
Session Start
├─→ health-check.sh: 9-section validation
├─→ session-start-inject.sh: mandatory checklist + F1 alerts + loop failure alerts
├─→ [plugin] loop-budget-check.sh: budget status
│
User sends message
├─→ post-task-detect.sh: completion keywords? → write reminder
├─→ multiagent-detect.sh: parallel dispatch? → suggestion
│
... AI executes task ...
│
User says "搞定了" / "done"
├─→ post-task-detect.sh detects → injects Tier1/Tier2 write reminder
│
Session End
├─→ training-collect.sh → compute EMA/F1 → update meta.json
├─→ [plugin] loop-failure-check.sh → scan failure modes → update failure-report.json
```

---

## Requirements

- Claude Code CLI v2.1+
- Python 3.8+ (for inline Python in hooks)
- Bash (Linux / macOS / WSL) or Git Bash (Windows)

---

## Acknowledgements

lean-hooks draws inspiration from:

- **[Loop Engineering](https://github.com/cobusgreyling/loop-engineering)** — Loop governance primitives, readiness levels, design checklist, failure mode catalog
- **[Everything Claude Code (ECC)](https://github.com/affaan-m/ECC)** — Hook runtime control, security audit patterns, rules layering
- **[LangGraph](https://github.com/langchain-ai/langgraph)** — Stateful agent orchestration, two-phase detection architecture
- **[claude-mem-lite](https://github.com/thedotmack/claude-mem-lite)** — SQLite-backed session log search
- **[CodeGraph](https://github.com/anthropics/codegraph)** — Tree-sitter knowledge graph for structural code queries
- **[superpowers](https://github.com/claude-plugins-official/superpowers)** — Skill system patterns and feedback loop design
- **Claude Code** — The hook infrastructure that makes this project possible

**Vibe Coded**: This entire project was built through vibe coding — ideas and direction from the author, every line written by Claude Code.

## License

MIT
