# lean-hooks Architecture

A Claude Code hook harness providing automated memory, feedback loops, and multi-agent detection.

## Hook Lifecycle

Three Claude Code hook events are wired:

```
SessionStart ──► health-check.sh       (validates filesystem integrity)
             ──► session-start-inject.sh (injects memory index + skill checklist)

UserPromptSubmit ──► multiagent-detect.sh  (two-phase parallel-agent detection)
                 ──► post-task-detect.sh   (completion keyword detection)

Stop ──► skillopt-collect.sh (parses feedback.md, updates meta.json counters)
```

Each script sources `harness/env.sh` for Python detection (`$PY`) and config root (`$HARNESS_ROOT`).

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
4. **Alert**: `training-collect.sh` syncs meta.json; at 3+ signals, `session-start-inject.sh` surfaces alert
5. **Improve**: AI reviews past patterns and self-corrects

Cycle: Observe → Evaluate → Record → Alert → Improve (next session)

## Memory System

### Tier 1: Auto Session Logs
`post-task-detect.sh` detects completion keywords and prompts the AI to write a 1-line session summary to a SQLite database (`data/claude-mem.db`). Pure chat sessions are skipped.

### Tier 2: Manual Structured Memory
Users explicitly save lessons via "remember this" or at the end of debugging sessions. Stored as markdown files with frontmatter in `projects/<name>/memory/`, indexed in `MEMORY.md`.

## Environment Detection

`harness/env.sh` provides unified configuration:
- `$PY` — Python interpreter (from `$HARNESS_PYTHON` env var or auto-detected)
- `$HARNESS_ROOT` — config directory root (from env var or derived from script location)
- Common path variables: `$MEMORY_DIR`, `$FEEDBACK_DIR`, `$MULTIAGENT_DIR`, `$MEM_DB`

## Directory Layout

```
~/.claude/
├── harness/              # Hook scripts (installed from harness-repo/harness/)
├── skill-feedback/       # SkillOpt feedback.md + meta.json
├── multiagent-feedback/  # MultiAgentOpt feedback.md + meta.json
├── rules/                # Language-specific rule files (scaffold)
├── memory/               # Tier 2 manual memory (markdown + frontmatter)
├── projects/             # Per-project memory subdirectories
├── data/                 # SQLite database (claude-mem.db)
├── settings.json         # Claude Code hooks configuration
└── CLAUDE.md             # AI behavior guidelines
```
