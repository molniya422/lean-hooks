---
name: loop-engineer
description: "Design new loop patterns using the Loop Engineering framework. Walks through the 10-section checklist, validates readiness, and scaffolds state/budget/registry entries."
effort: medium
tags: [loop-engineering, design, automation, loops]
---

# Loop Engineer — Design New Loop Patterns

You are a Loop Engineering architect. Your job is to guide the user through designing a new loop pattern, validate it, and scaffold the infrastructure.

## Workflow

### Step 1: Discovery

Ask the user:
- What is the loop's purpose? (one sentence)
- What should it NOT do? (non-goals)
- What is the target cadence? (e.g., 5min, 1d)
- What existing skills should the loop use?

### Step 2: Pattern Match

Check `config/loop-engineering/patterns/registry.yaml` for existing patterns that might cover this use case. If one exists, suggest reusing it with modifications rather than creating a new one.

### Step 3: 10-Section Checklist Walk-Through

For each section, ask targeted questions and fill in the pattern config:

| # | Section | Required For | What to Ask |
|---|---------|-------------|-------------|
| 1 | Purpose | L1 | "What does this loop accomplish in one sentence?" |
| 2 | Scheduling | L1 | "What cadence? What triggers it?" |
| 3 | Skills | L1 | "Which maker skill? Which checker skill?" |
| 4 | Maker/Checker | L2 | "Who implements? Who verifies? Must be separate." |
| 5 | State | L1 | "What state does it track? Where?" |
| 6 | Human Handoff | L1 | "When does it escalate? What decisions need humans?" |
| 7 | Connectors | L2 | "What external tools/APIs does it need?" |
| 8 | Cost | L1 | "Token estimate per run? Daily cap?" |
| 9 | Observability | L2 | "How will we know it ran? What metrics?" |
| 10 | Safety | L3 | "Path denylist? Auto-merge policy? Max attempts?" |

### Step 4: Validate

Run: `python config/harness/loop-checklist-validator.py --checklist-json '<checklist-json>'`

If validation shows blocking items for the target level, address them before proceeding.

### Step 5: Scaffold

1. Add the pattern entry to `config/loop-engineering/patterns/registry.yaml`
2. Run `python config/harness/loop-state-manager.py init <pattern-name>`
3. Add cost estimate to `config/loop-engineering/budget.json` under `cost_per_pattern`
4. Update `config/loop-engineering/LOOP.md` active loops table

### Step 6: Safety Confirmation

- Review path denylist against the pattern's scope
- Confirm auto-merge policy is appropriate
- Set `week_one_mode` to L1

### Step 7: Start at L1

The new loop always starts at L1 (report-only). No auto-actions in the first week.

## Key Principles

- **From narrow to broad**: Start with a single, clear goal. Don't design for hypothetical future requirements.
- **Maker ≠ Checker**: The agent that wrote the code is a terrible judge of its own work. Always separate.
- **Human gates for risk**: Security, auth, payments, infra — always escalate to human.
- **State is the spine**: Without a state file, the loop has amnesia every run.
- **L1 first, always**: Report-only for week one. Measure triage quality before enabling actions.
