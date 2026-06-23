# Loop Engineering Safety Policy

Safety guardrails for all loop patterns operating in this harness.

## Path Denylist

Loops must **never** auto-edit these paths without human approval:

```
.env
.env.*
**/secrets/**
**/credentials/**
**/*_key*
**/*_secret*
C:/**                    # No C: drive access per CLAUDE.md §5
**/migrations/**        # Unless explicit migration loop
auth/**
payments/**
billing/**
```

## Auto-Merge Policy

| Level | Auto-merge | Scope |
|---|---|---|
| L1 | **Never** | Report-only, no code changes |
| L2 | Allowlisted only | `*.md`, `*.json` in non-critical dirs, comments |
| L3 | With post-merge verify | Allowlisted paths + verifier post-check |

Explicit path allowlist per pattern is defined in `patterns/registry.yaml`.

## Tool Scope Limits

Each pattern declares `tools` in its registry entry. A pattern attempting to use an undeclared tool is flagged as `over_reach` by the failure detector.

## Kill Switch

- Environment variable: `LOOP_BUDGET_EXHAUSTED=1` — all loop executions must skip
- Budget file: `budget.json` daily_token_cap reached — loops automatically pause
- Manual: Set any pattern's state `status` to `"paused"` via `loop-state-manager.py write <pattern> status paused`

## Escalation Rules

1. Critical failures must escalate to human within 1 session
2. Patterns with `consecutive_failures >= 3` auto-disable (status → "paused")
3. Escalated items unresolved > 7 days trigger `escalation_failure` alert
4. Maximum 5 escalations per 24h before `notification_fatigue` alert

## Data Protection

- Loops must not delete data they did not create
- Archive instead of delete (use `loop-run-logger.py prune` for safe archival)
- State files are append-friendly; prune requires explicit command
- Run logs are append-only (only prune via `loop-run-logger.py prune --older-than 90`)

## Human Gates (Required)

Always require human approval for:
- Security, authentication, authorization changes
- Payments, billing, PII handling
- Infrastructure / Terraform / K8s production
- Dependency upgrades (supply chain risk)
- Changes touching >10 files
- Third attempt on same item (max 3, then escalate)
