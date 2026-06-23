---
name: loop-audit
description: "Run loop readiness audit and failure analysis. Scores 0-100, assigns readiness level L0-L3, detects failure modes, and suggests improvements."
effort: low
tags: [loop-engineering, audit, readiness, failure-modes]
---

# Loop Audit — Readiness Check & Failure Analysis

Run a comprehensive audit of the harness's loop infrastructure.

## Workflow

### Step 1: Run Readiness Audit

```bash
python config/harness/loop-readiness-audit.py --suggest
```

Record the score and level.

### Step 2: Run Failure Detection

```bash
python config/harness/loop-failure-detector.py report
```

Check for any active failure modes.

### Step 3: Validate Checklists

For each pattern in the registry:

```bash
python config/harness/loop-checklist-validator.py --pattern <name>
```

### Step 4: Budget Check

```bash
python config/harness/loop-budget-tracker.py check --json
```

### Step 5: Summarize

Present a summary table:

| Metric | Value |
|--------|-------|
| Readiness Score | X/100 |
| Readiness Level | L? |
| Active Failures | N (C critical, H high, M medium) |
| Healthy Patterns | list |
| Daily Budget Used | X% (Y/Z tokens) |
| Blocking for L2 | list |
| Blocking for L3 | list |

### Step 6: Suggest Actions

Based on findings, prioritize:
1. **Critical**: Fix any failure-mode detections first
2. **Level advancement**: Address blocking items for the next readiness level
3. **Efficiency**: Optimize token costs or cadence for high-cost patterns
4. **Coverage**: Add patterns for work not yet covered by any loop

## Interpretation Guide

| Level | What It Means |
|-------|---------------|
| L0 | Infrastructure partial, no loops running |
| L1 | Report-only loops operational, measuring quality |
| L2 | Assisted fixes with maker/checker split, human gates |
| L3 | Unattended loops with full safety guardrails |

## When to Run

- On session start (quick check is automatic via health-check)
- After designing a new loop (validate readiness)
- After a failure incident (assess blast radius)
- Weekly (track readiness score trend)
