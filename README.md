# lean-hooks

> A portable, zero-dependency automation harness for Claude Code. Hooks, memory, skill optimization, multi-agent detection, semantic attention, and loop engineering — all in one install.

---

## Why lean-hooks?

Claude Code has hook events (`SessionStart`, `UserPromptSubmit`, `Stop`) but no built-in system to remember across sessions, improve its own behavior, or govern automated loops. lean-hooks fills that gap:

- **Never repeat work** — cross-session memory + SQLite session logs
- **Get better over time** — behavioral quality feedback loop with EMA/F1 metrics
- **Detect complexity** — two-phase heuristic suggests parallel agents when tasks warrant it
- **Govern automation** — loop engineering with budget kill switches, failure detection, and readiness levels
- **Match skills semantically** — ONNX embedding layer finds the right skill for the right prompt (optional)

All hooks **inject context** — they never execute AI operations directly. The AI retains judgment over whether to act.

---

## Quick Start

```bash
git clone https://github.com/molniya422/lean-hooks.git
cd lean-hooks

# Linux / macOS / WSL
./install.sh

# Windows PowerShell
.\install.ps1

# Done. Restart Claude Code.
```

No Python packages to install. No Node dependencies. Just bash + Python 3.8+.

---

## How It Works

Three autonomous feedback loops, wired into Claude Code's hook events:

```
Session Start ──► health-check + security-audit + memory inject + F1 alerts + budget warnings

User sends message ──► completion keyword detect + parallel agent suggestion + skill attention match

Session End ──► training-collect (P/R/F1/EMA) + loop failure scan + budget tracking
```

### Loop 1: Memory

```
Session with substance ──► auto-summary.py ──► SQLite session_logs
User says "remember"   ──► memory/*.md     ──► MEMORY.md index
Next session           ──► injected memory hint ──► AI searches before repeating work
```

### Loop 2: TrainingLoop

```
AI observes quality issue ──► writes feedback.md (3 dimensions)
Session Stop              ──► training-collect.py computes P/R/F1/EMA/loss
F1 < target (3+ sessions) ──► auto-adjusts multiagent threshold
Next SessionStart        ──► F1 alert injected ──► AI self-corrects
```

Three dimensions tracked:

| Dimension | What It Measures | Feedback Types |
|---|---|---|
| **SkillOpt** | Skill trigger accuracy | Correct / Miss / False Positive |
| **MultiAgentOpt** | Agent dispatch accuracy | Correct / Miss / False Positive |
| **ToolCallOpt** | Tool call quality | Positive / Negative / Missed Opportunity |

Loss function: `L = [(1-P)² + (1-R)²] / [(1-P)+(1-R)+ε] + γ·complexity`

**v2.2 safety gates**: System starts in L0 (report-only) mode. Auto-adjustment disabled until ≥50 feedback signals globally, ≥10 per dimension. Zero signals → `has_data=False` (not vacuous P=R=F1=1.0).

### Loop 3: Loop Engineering

```
Loop executes  ──► run-logger.py records audit trail
State changes  ──► state-manager.py per-pattern state
Tokens used    ──► budget-tracker.py daily/weekly caps
Session Stop   ──► failure-detector.py scans 9 failure modes
Next Start     ──► budget warnings + critical failure alerts
```

---

## Architecture

```
~/.claude/
├── lean-hooks.toml              ← per-hook config (timeout, enabled, events)
├── settings.json                ← hook chain wired here
├── CLAUDE.md                    ← behavioral rules + skill trigger table
│
├── harness/                     ← all hook scripts
│   ├── env.sh                   ← Python/root/path detection (dual-layout)
│   ├── error-handler.sh         ← timeout + non-blocking error logging
│   ├── plugin-loader.sh         ← drop-in plugin auto-registration
│   │
│   ├── health-check.sh          ← 9-section integrity validation
│   ├── security-audit.sh        ← .env / plaintext key scanner
│   ├── session-start-inject.sh  ← 7-block context injection
│   ├── post-task-detect.sh      ← ~60 completion keyword detector
│   ├── multiagent-detect.sh     ← two-phase parallel agent scorer
│   ├── training-collect.sh/py   ← 3-dimension EMA metrics engine
│   │
│   ├── auto-summary.py          ← session log → SQLite
│   ├── data-lifecycle.py        ← MEMORY.md rotation + archival
│   ├── weighted-scoring.py      ← time-decay F1 + trend analysis
│   ├── stats.py                 ← query CLI
│   ├── test_all.py              ← integration test suite
│   ├── db-migrate.py            ← SQLite schema migration
│   ├── role-collab-runner.py    ← multi-role parallel review orchestrator
│   ├── skill-attention.py       ← ONNX semantic skill matching (optional)
│   ├── skill-attention-query.sh ← hook wrapper for skill-attention
│   │
│   │  // loop-engineering scripts
│   ├── loop-state-manager.py
│   ├── loop-run-logger.py
│   ├── loop-budget-tracker.py
│   ├── loop-readiness-audit.py
│   ├── loop-failure-detector.py
│   └── loop-checklist-validator.py
│
├── hooks/                       ← drop-in plugin directory
├── training-loop/               ← feedback + metrics
│   ├── feedback.md
│   ├── meta.json
│   ├── metrics_core.py          ← shared computation (v2.2)
│   ├── adaptive-threshold.py    ← standalone optimizer (v2.2)
│   ├── metrics-design.md
│   └── metrics-schema.json
│
├── loop-engineering/            ← loop governance
│   ├── LOOP.md                  ← active loops + coordination
│   ├── safety.md                ← path denylist + auto-merge rules
│   ├── patterns/registry.yaml   ← 8 pattern definitions
│   ├── states/                  ← per-pattern mutable state (8 files)
│   ├── budget.json
│   ├── run-log.jsonl
│   ├── failure-report.json
│   └── archive/
│
├── data/                        ← SQLite DB
├── memory/                      ← MEMORY.md + per-project files
└── ERRORS.md                    ← auto-generated error log
```

---

## Hook Chain

| Event | Script | What It Does |
|---|---|---|
| **SessionStart** | `health-check.sh` | 9-section integrity validation |
| | `security-audit.sh` | .env/gitignore scanning |
| | `session-start-inject.sh` | Memory index + 3-step checklist + F1 alerts + loop failure alerts |
| **UserPromptSubmit** | `post-task-detect.sh` | Detects ~60 completion keywords → write reminder |
| | `multiagent-detect.sh` | Two-phase scoring → parallel agent suggestion |
| | `skill-attention-query.sh` | Semantic skill matching (optional, disabled by default) |
| **Stop** | `training-collect.sh` | Parses feedback → computes EMA/F1 → updates meta.json |

---

## Key Features

### Non-Blocking Error Handling

```
[Hook] ──► timeout_wrap ──► success ──► continue
                          └── failure ──► ERRORS.md ──► continue
```

No hook ever blocks your session. Configurable timeouts via `lean-hooks.toml`.

### Multi-Agent Detection

Two-phase heuristic: fast keyword filter (0 cost) → structural analysis (task verbs, file refs). Biases toward false negatives. Threshold auto-tightens/loosens based on F1.

```bash
echo '{"prompt":"fix auth and refactor login"}' | bash harness/multiagent-detect.sh --dry-run
```

### SkillAttention (Optional)

ONNX semantic embedding layer: user prompt → all-MiniLM-L6-v2 embedding → cosine similarity against skill utterance database → gated by per-skill attention weights. Requires `SKILL_ATTENTION_MODEL_DIR` env var. Gracefully disabled when not configured.

### Plugin System

Drop `.sh` files into `hooks/` with naming convention `<Event>[_<Priority>]--<Name>.sh`:

```
hooks/
├── SessionStart_08--loop-budget-check.sh   ← budget warnings
├── SessionStart_10--custom-health.sh       ← custom checks
└── Stop_10--loop-failure-check.sh          ← failure scan
```

### Stats CLI

```bash
python harness/stats.py                  # dashboard
python harness/stats.py sessions         # session list
python harness/stats.py hooks            # hook error analysis
python harness/stats.py skills           # SkillOpt P/R/F1
python harness/stats.py multiagent       # MultiAgentOpt analysis
python harness/stats.py trends --json    # machine-readable trends
```

### Data Lifecycle

| Data | Threshold | Action |
|---|---|---|
| `MEMORY.md` | >64 KB | Rotated to `archive/` |
| Session logs | >90 days | Archived to `archive/` |
| `ERRORS.md` | >1 MB | Rotated to `archive/` |

---

## 8 Loop Patterns

| Pattern | Cadence | Risk | Maker | Checker |
|---|---|---|---|---|
| Daily Triage | 1d | low | `issue-triage` | `verification-before-completion` |
| PR Babysitter | 5-15m | high | `babysit` | `requesting-code-review` |
| CI Sweeper | 5-15m | very high | `systematic-debugging` | `verification-before-completion` |
| Dependency Sweeper | 6h-1d | medium | `security-guardian` | `verification-before-completion` |
| Changelog Drafter | 1d | low | `repo-recap` | `verification-before-completion` |
| Post-Merge Cleanup | 1d-6h | low | `finishing-a-development-branch` | `verification-before-completion` |
| Issue Triage | 2h-1d | low | `issue-triage` | `verification-before-completion` |
| Role-Collab | on-demand | medium | `role-collab` | `verification-before-completion` |

Each pattern starts at **L0** (draft) → **L1** (report-only) → **L2** (assisted fixes + human gates) → **L3** (unattended). Advancement requires zero critical failures, readiness-audit score ≥65 (L2) or ≥85 (L3), and explicit human approval.

### 9 Failure Modes Detected

`infinite_fix_loop` · `state_rot` · `verifier_theater` · `notification_fatigue` · `token_burn` · `over_reach` · `escalation_failure` · `dead_loop` · `budget_blowout`

---

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `HARNESS_PYTHON` | auto-detected | Override Python interpreter |
| `HARNESS_ROOT` | auto-detected | Override config root directory |
| `DISABLED_HOOKS` | — | Comma-separated hook names to disable |
| `PROJECT_NAME` | auto-detected | Per-project config override |
| `LOOP_BUDGET_EXHAUSTED` | — | Set `1` to block all loop executions |
| `SKILL_ATTENTION_MODEL_DIR` | — | ONNX model dir (enables SkillAttention) |
| `SKILL_ATTENTION_PYTHON` | `$PY` | Python with onnxruntime + tokenizers |
| `CLAUDE_MEM_DATA_DIR` | auto-detected | Override claude-mem database dir |

---

## Session Lifecycle

```
Session Start
├─ health-check.sh: 9-section validation
├─ session-start-inject.sh: checklist + F1 alerts + loop alerts
├─ [plugin] loop-budget-check.sh: budget status
│
User message
├─ post-task-detect.sh: completion? → write reminder
├─ multiagent-detect.sh: complex? → agent suggestion
├─ skill-attention-query.sh: semantic skill match (if enabled)
│
... AI works ...
│
Session End
├─ training-collect.sh: compute EMA/F1 → update meta.json
├─ [plugin] loop-failure-check.sh: scan 9 failure modes
```

---

## Requirements

- Claude Code CLI v2.1+
- Python 3.8+ (for inline scripting in hooks)
- Bash (Linux / macOS / WSL) or Git Bash (Windows)

**Optional** (SkillAttention):
- `onnxruntime` + `tokenizers` Python packages
- all-MiniLM-L6-v2 ONNX model → set `SKILL_ATTENTION_MODEL_DIR`

---

## Acknowledgements

- **[Loop Engineering](https://github.com/cobusgreyling/loop-engineering)** — governance primitives, readiness levels, failure mode catalog
- **[Everything Claude Code](https://github.com/affaan-m/ECC)** — hook runtime control, security audit patterns
- **[LangGraph](https://github.com/langchain-ai/langgraph)** — stateful agent orchestration
- **[claude-mem-lite](https://github.com/thedotmack/claude-mem-lite)** — SQLite session log search
- **[CodeGraph](https://github.com/anthropics/codegraph)** — tree-sitter knowledge graph
- **Claude Code** — the hook infrastructure that makes this possible

**Vibe Coded**: Ideas and direction from the author, every line written by Claude Code.

## License

MIT
