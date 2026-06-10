# lean-hooks Architecture

A Claude Code hook harness providing automated memory, feedback loops, and multi-agent detection.

## Hook Lifecycle

Three Claude Code hook events are wired:

```
SessionStart ──► health-check.sh       (validates filesystem integrity)
             ──► security-audit.sh     (lightweight security scan)
             ──► session-start-inject.sh (injects memory index + skill checklist)

UserPromptSubmit ──► post-task-detect.sh   (completion keyword detection)
                 ──► multiagent-detect.sh  (two-phase parallel-agent detection)

Stop ──► training-collect.sh (parses feedback.md, updates meta.json counters)
```

Each script sources `harness/env.sh` for Python detection (`$PY`) and config root (`$HARNESS_ROOT`).

## New in v2: Enhanced Architecture

### Error Handling (error-handler.sh)

Every hook is automatically wrapped with:
- **timeout_wrap**: Runs hook with a configurable timeout (default 30s). On timeout → logs to ERRORS.md, does NOT crash session.
- **error_log**: Writes structured error records to `ERRORS.md` with timestamp, hook name, exit code, and error message.
- **safe_run**: One-call hook execution that handles config resolution, timeout, and error logging.
- **Auto-pruning**: ERRORS.md entries older than 30 days are pruned on write.

```
 [User Prompt] ──► post-task-detect.sh ──► timeout 10s ──► success? ──► continue
                                                    └── failure? ──► ERRORS.md ──► continue
```

### Granular Configuration (lean-hooks.toml)

Replaces `DISABLED_HOOKS` env var with structured config:

```toml
[[hook]]
name = "multiagent-detect"
file = "harness/multiagent-detect.sh"
events = ["UserPromptSubmit"]
timeout = 15
enabled = true
```

### Plugin System (plugin-loader.sh)

Auto-discovers hooks from `hooks/*.sh` with priority ordering:

```
hooks/
├── SessionStart_10--custom-health.sh    ← priority 10 (runs first)
├── SessionStart_50--audit.sh            ← priority 50
├── UserPromptSubmit_80--logger.sh       ← priority 80
└── Stop_99--cleanup.sh                  ← priority 99
```

Naming convention: `<Event>[_<Priority>]--<Name>.sh`. Default priority = 100.

### Data Lifecycle Management

```
┌──────────────────────────────────────────────────────────────────┐
│                        data-lifecycle.py                         │
│                                                                  │
│  MEMORY.md > 64KB ──► archive/MEMORY.YYYY-MM-DD.md              │
│  Sessions > 90d   ──► archive/session_logs.YYYY-MM-DD.jsonl     │
│  ERRORS.md > 1MB  ──► archive/ERRORS.YYYY-MM-DD.md              │
└──────────────────────────────────────────────────────────────────┘
```

### Weighted Scoring (weighted-scoring.py)

Enhances TrainingLoop metrics with:
- **Time-decay weights**: Recent observations count more (half-life = 10 sessions)
- **Per-type weights**: Correct triggers (+1.0), misses (-0.8), false positives (-0.6)
- **Trend analysis**: Improving / declining / fluctuating
- **Confidence scoring**: Scale from 0.0 (no data) to 1.0 (high confidence)

### Stats CLI (stats.py)

Multi-command query tool for session/hook/feedback data:

```
lean-hooks stats dashboard    # summary of all systems
lean-hooks stats sessions     # session log listing
lean-hooks stats hooks        # hook error analysis
lean-hooks stats skills       # SkillOpt metrics
lean-hooks stats multiagent   # MultiAgentOpt metrics
lean-hooks stats trends       # session trends over time
lean-hooks stats --json       # machine-readable output
```

## Two-Phase Multi-Agent Detection

`multiagent-detect.sh` runs on every user prompt to decide whether the task would benefit from parallel agent dispatch.

### Phase 1: Fast Heuristic Filter
- Zero API cost, zero latency
- Pattern matching on keywords, message length, exclusion rules
- Filters ~95% of casual chat, greetings, simple questions
- Direct trigger at score >= 4; uncertain zone [2, 4) escalates to Phase 2

### Phase 2: Heuristic Enhancement
- Structural analysis: counts distinct task verbs, file references, technology boundaries
- Applies dampening for isolated signals without structural support
- Trigger at score >= 3 after Phase 2
- Future: swappable with LLM classifier (interface already in code)

### `--dry-run` Mode

```
echo '{"prompt":"fix auth and refactor login"}' | bash multiagent-detect.sh --dry-run

Input text (43 chars): fix auth and refactor login

Phase 1 score: 2
  Reasons: moderate_keyword
Phase 2 score: 3
  Reasons: moderate_keyword, multi_verb, multi_file

Final score: 3
Decision: NO TRIGGER (< 4)
```

## Unified TrainingLoop

Three training dimensions share one structured feedback system at `training-loop/`:

- **SkillOpt** — skill trigger accuracy (misses + false positives)
- **MultiAgentOpt** — agent dispatch accuracy (misses + false positives)
- **ToolCallOpt** — tool call pattern quality (positive + negative observations)

All three write to the same `feedback.md` under their `##` sections. A single `meta.json` tracks all counters across `dimensions.skill`, `dimensions.multiagent`, `dimensions.toolcall`.

### Workflow

1. **Observe**: `post-task-detect.sh` prompts unified TrainingLoop reflection
2. **Evaluate**: AI judges behavioral quality across all three dimensions
3. **Record**: Observations written to `training-loop/feedback.md` (single file)
4. **Score**: `weighted-scoring.py` computes time-decay F1 with trend analysis
5. **Alert**: `training-collect.sh` syncs meta.json; at 3+ signals, `session-start-inject.sh` surfaces alert
6. **Improve**: AI reviews past patterns and self-corrects

Cycle: Observe → Evaluate → Record → Score → Alert → Improve (next session)

## Memory System

### Tier 1: Auto Session Logs
`post-task-detect.sh` detects completion keywords and prompts the AI to write a 1-line session summary to a SQLite database (`data/claude-mem/claude-mem.db`). Pure chat sessions are skipped.

### Tier 2: Manual Structured Memory
Users explicitly save lessons via "remember this" or at the end of debugging sessions. Stored as markdown files with frontmatter in `projects/<name>/memory/`, indexed in `MEMORY.md`.

### Lifecycle
`data-lifecycle.py` automatically rotates MEMORY.md (>64KB) and archives old sessions (>90 days) to keep data manageable.

## Environment Detection

`harness/env.sh` provides unified configuration:
- `$PY` — Python interpreter (from `$HARNESS_PYTHON` env var or auto-detected)
- `$HARNESS_ROOT` — config directory root (from env var or derived from script location)
- `$CONFIG_DIR` — config subdirectory (supports dual-layout: config/ or root)
- Common path variables: `$MEMORY_DIR`, `$LOOP_DIR`, `$HARNESS_DIR`, `$CLAUDE_MD`
- `$ERRORS_FILE` — error log path (default: CONFIG_DIR/ERRORS.md)
- `$_LOADED_HOOKS_CFG` — detected lean-hooks.toml path

## Directory Layout

```
~/.claude/
├── lean-hooks.toml                  ← granular config (new)
├── settings.json                    ← Claude Code hooks configuration
├── CLAUDE.md                        ← AI behavior guidelines
├── harness/                         ← all hook scripts
│   ├── env.sh                       ← environment detection
│   ├── error-handler.sh             ← timeout + error logging (new)
│   ├── plugin-loader.sh             ← plugin auto-registration (new)
│   ├── health-check.sh
│   ├── security-audit.sh
│   ├── session-start-inject.sh
│   ├── post-task-detect.sh
│   ├── multiagent-detect.sh
│   ├── training-collect.sh
│   ├── auto-summary.py
│   ├── training-collect.py
│   ├── data-lifecycle.py            ← rotation/archiving (new)
│   ├── weighted-scoring.py          ← enhanced F1 scoring (new)
│   ├── stats.py                     ← query CLI (new)
│   └── test_all.py                  ← integration tests (new)
├── hooks/                           ← drop-in plugin directory (new)
│   └── SessionStart_10--custom-health.sh
├── training-loop/
│   ├── feedback.md                  ← unified feedback (all 3 dims)
│   ├── meta.json                    ← counters + EMA + weighted scores
│   └── metrics-design.md
├── skill-feedback/                  ← (legacy, migration to training-loop/)
├── multiagent-feedback/             ← (legacy, migration to training-loop/)
├── rules/                           ← language-specific rule files
├── memory/                          ← Tier 2 manual memory (markdown + frontmatter)
├── projects/                        ← per-project memory subdirectories
├── data/                            ← SQLite database (claude-mem.db)
└── archive/                         ← rotated/archived data (new)
```

## Integration Test Suite

`harness/test_all.py` covers:

| Test Group | What It Validates |
|---|---|
| `error` | timeout_wrap, error_log, safe_run, ERRORS.md |
| `config` | lean-hooks.toml parsing, is_hook_enabled |
| `env` | env.sh detection, path resolution |
| `multiagent` | Phase 1/2 scoring, --dry-run output |
| `summary` | auto-summary.py DB write |
| `metrics` | training-collect.py F1/EMA computation |
| `lifecycle` | data-lifecycle.py rotation/archive |

Run: `python harness/test_all.py`
