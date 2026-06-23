---
harness_version: "5.0"
loop_engineering_version: "1.0"
last_audit_score: 0
last_audit_level: "L0"
---

# LOOP.md — Harness Loop Coordination

## Active Loops

| Pattern | Level | Status | Last Run | Consecutive Failures |
|---------|-------|--------|----------|---------------------|
| daily-triage | L0 | active | never | 0 |
| pr-babysitter | L0 | inactive | never | 0 |
| ci-sweeper | L0 | inactive | never | 0 |
| dependency-sweeper | L0 | inactive | never | 0 |
| changelog-drafter | L0 | inactive | never | 0 |
| post-merge-cleanup | L0 | inactive | never | 0 |
| issue-triage | L0 | inactive | never | 0 |

## Multi-Loop Coordination Rules

1. No two loops may modify the same file in the same run
2. PR-babysitter and CI-sweeper are mutually exclusive per-PR
3. Post-merge-cleanup waits for PR-babysitter to complete
4. Daily-triage runs before issue-triage (dependency)
5. Dependency-sweeper and CI-sweeper coordinate on test execution
6. Changelog-drafter runs after post-merge-cleanup (needs merged history)

## Budget Status

- Daily token cap: 500,000
- Daily run cap: 50
- Weekly token cap: 2,000,000
- Current usage today: 0
- Remaining: 100%

## Safety Gates

- [x] Path denylist configured (safety.md)
- [x] Auto-merge policy defined (L1: never → L2: allowlisted → L3: post-verify)
- [x] Kill switch (budget exhaustion) active
- [x] Max-retry limits per pattern (3 attempts)
- [ ] Maker/checker split verified for all L2+ patterns
- [ ] Failure mode catalog loaded and active
- [ ] All patterns initialized with state files

## Rollout Plan

- Week 1: Initialize all pattern states at L0. Report-only observation.
- Week 2: Activate L1 for daily-triage, issue-triage, changelog-drafter (lowest risk)
- Week 3: Activate L1 for dependency-sweeper, post-merge-cleanup if 0 failures
- Week 4: Activate L2 for daily-triage if checklist-validator confirms all L2 sections
- Week 5+: Evaluate L3 per pattern based on failure history

## Evolution

Advancement L1→L2 requires:
1. Zero critical failures in L1 over 7 days
2. checklist-validator confirms all L2 sections present
3. readiness-audit score >= 65 for that pattern
4. Explicit human approval documented in state file

Advancement L2→L3 requires:
1. All of the above plus
2. Failure detector reports zero unresolved failures
3. readiness-audit score >= 85
4. Safety policy fully validated for the pattern
