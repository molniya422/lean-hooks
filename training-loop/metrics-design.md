# ML-Inspired Training Metrics System

## 1. Event Model & Confusion Matrix Definitions

For each dimension, every trigger / dispatch / tool-usage decision is classified into one of four categories.  TN (correct inaction) is generally unobservable and not stored.

| Category | Generic Definition |
|----------|-------------------|
| **TP** | Correct action taken |
| **FP** | Incorrect action taken |
| **FN** | Correct action required but not taken |
| **TN** | Correct inaction (untracked) |

### 1.1 SkillOpt — Skill Trigger Accuracy

- **Decision event**: A user message is received and evaluated against the CLAUDE.md Section 0 trigger table.
- **TP**: The skill matched the message, was invoked, and post-task reflection confirms it was appropriate.  Logged as `### Correct Trigger` under `## SkillOpt` in `feedback.md`.
- **FP**: A skill was invoked but was irrelevant or wrong.  Logged as `### False Positive`.
- **FN**: A skill should have been invoked but was not.  Logged as `### Miss`.

### 1.2 MultiAgentOpt — Agent Dispatch Accuracy

- **Decision event**: The `multiagent-detect.sh` heuristic scores a `UserPromptSubmit` message.
- **TP**: Score was >= threshold AND the message genuinely warranted parallel agents.  Logged as `### Correct Trigger` under `## MultiAgentOpt`.
- **FP**: Score was >= threshold but the message did NOT warrant parallel agents.  Logged as `### False Positive`.
- **FN**: Score was < threshold but the message DID warrant parallel agents.  Logged as `### Miss`.

### 1.3 ToolCallOpt — Tool Call Pattern Quality

- **Decision event**: A tool-call pattern is executed within a session.
- **TP**: The pattern was efficient and correct.  Logged as `### Positive` under `## ToolCallOpt`.
- **FP**: The pattern was wasteful or wrong.  Logged as `### Negative`.
- **FN**: A better pattern was available but not used (e.g. batching opportunity missed).  Logged as `### Missed Opportunity`.

---

## 2. Metrics Formulas

For each dimension *d*, given counts (TP, FP, FN):

```
Precision(d)  = TP_d / (TP_d + FP_d + ε)
Recall(d)     = TP_d / (TP_d + FN_d + ε)
F1(d)         = 2 * Precision(d) * Recall(d) / (Precision(d) + Recall(d) + ε)
```

with `ε = 1e-8` to prevent division by zero.  Boundary convention:
- When **TP = FP = FN = 0**, return `precision = recall = f1 = None` with `has_data = False`.  This prevents vacuous correctness (Problem 5): previously, returning P=R=F1=1.0 for zero signals caused EMA to drift toward 1.0, masking real problems.  Callers must check `has_data` before using metrics.  When `has_data = False`, EMA is not updated.

---

## 3. Adaptive Loss Function

### 3.1 Core Loss (Precision–Recall)

The weights adapt so that the metric that is performing worse receives higher penalty.

```
α_base(d) = 1 − Precision(d)
β_base(d) = 1 − Recall(d)
denom(d)  = α_base(d) + β_base(d) + ε

α(d) = α_base(d) / denom(d)
β(d) = β_base(d) / denom(d)

L_core(d) = α(d) · (1 − Precision(d)) + β(d) · (1 − Recall(d))
```

Algebraic simplification:
```
L_core(d) = [(1 − P)^2 + (1 − R)^2] / [(1 − P) + (1 − R) + ε]
```

Boundary behavior:
- If `P = 1`, `R < 1`:  `L_core = 1 − R`  (only recall matters).
- If `R = 1`, `P < 1`:  `L_core = 1 − P`  (only precision matters).
- If `P = R = 1`:       `L_core = 0`.

### 3.2 Complexity Penalty

Discourages excessive invocations, dispatches, or tool calls above a per-dimension baseline.

```
C_target:
  skill:      2.0   (avg skill invocations per substantive session)
  multiagent: 0.5   (avg parallel-dispatch suggestions per session)
  toolcall:   8.0   (avg tool calls per substantive session)

C_norm(d) = max( 0 , (C_current(d) − C_target(d)) / C_target(d) )
```

`C_current` is populated by future harness instrumentation (e.g. counting per-session invocations from `session_logs`).  Until instrumented, `C_current = 0`.

### 3.3 Total Loss

```
γ = 0.15    (global complexity weight, stored in meta.json)

Loss(d) = L_core(d) + γ · C_norm(d)
```

Loss is bounded in `[0, 1 + γ]`.

---

## 4. Signal-Count EMA (v2.2)

Per-aggregate metrics are noisy.  Smoothed trajectories are computed with momentum, but **only when new signals arrive**, not on every session.

### 4.1 Why Signal-Count EMA

In the v2.1 design, EMA was applied to cumulative P/R/F1 on every session.  Since cumulative metrics only change when new feedback signals are added, across 386 sessions with ~12 signals the EMA smoothed 386 copies of the same slowly-changing value.  This is mathematically invalid — it treated 386 identical measurements as independent data points, inflating EMA confidence in stale values.

The v2.2 fix: **EMA updates only when the total signal count (TP+FP+FN) changes**.  `last_signal_count` is stored in `meta.json` per dimension alongside `last_updated_session`.  When `current_signal_count <= last_signal_count`, the EMA is unchanged.

### 4.2 Update Rule

```
λ = 2 / (N + 1)          # default N = 10 signals  →  λ ≈ 0.1818
```

Update rule for each metric `M ∈ {Precision, Recall, F1}` (only when new signals arrive):

```
if signal_count(t) > signal_count(t-1):
    EMA_M(t) = λ · M(t) + (1 − λ) · EMA_M(t−1)
else:
    EMA_M(t) = EMA_M(t−1)   # no change
```

Initialization: if no prior EMA exists, `EMA_M(0) = M(0)` (cold-start).

The EMA F1 is the **primary control signal** for threshold adjustment.

Effective memory window: `≈ 1/λ`.  With `λ = 0.2`, ~80% of weight lies in the last 10 signal updates and ~95% in the last 30 signal updates.

### 4.3 No-Data Handling (Vacuous Correctness Fix)

When `TP = FP = FN = 0`, `compute_metrics` returns `has_data = False` with all metric values as `None`.  In this state:
- EMA is **not** updated (the previous EMA values are preserved, or remain None if cold start)
- Loss is set to `0.0` (not the vacuous `0.0` from P=R=1.0)
- `should_adjust` returns `False`

This prevents the "perfect score" problem where zero-signal sessions accumulated as P=R=F1=1.0 in the EMA, biasing it toward 1.0 and masking real problems.

### 4.4 Reset

For sudden regime changes (e.g. after a major CLAUDE.md rewrite), reset EMA by setting `ema.last_updated_session = 0` and `ema.last_signal_count = 0` so that old behavior does not mask improvement.

---

## 5. Threshold Adjustment Algorithm

### 5.0 Prerequisites (v2.2)

Two global config gates must be satisfied before any dimension can trigger adjustment:

1. **`adjustment_enabled`** (default: `false`) — Master kill-switch.  When false, `should_adjust` always returns false.  Set to true only after the system has collected sufficient signals (>=50 total across all dimensions) to warrant automated adjustments.  This prevents premature threshold changes on statistically insignificant data.

2. **`min_signals_for_adjustment`** (default: `10`) — Per-dimension minimum.  A dimension with fewer than N total signals (TP+FP+FN) cannot trigger adjustment.  With only 3 samples, confidence intervals on P/R/F1 are +-30 percentage points, making any adjustment indistinguishable from random.

When adjustment is disabled or signals are insufficient, the system operates at **L0 (report-only)**: metrics are computed and displayed, but no config files are modified.

### 5.1 Trigger Condition

```
for each dimension d:
    if adjustment_enabled  AND  signals(d) >= min_signals_for_adjustment
        AND  EMA_F1(d) < f1_target  AND  (sessions − last_adjusted_session) >= min_interval:
        trigger adjustment
```

Defaults:
- `f1_target = 0.75`
- `min_interval = 3` sessions (prevents thrashing)

### 5.2 Direction Selection

```
if Precision(d) < Recall(d):
    direction = TIGHTEN   # reduce false positives
else:
    direction = LOOSEN    # reduce misses
```

### 5.3 Magnitude

```
worse_metric = min(Precision(d), Recall(d))
magnitude    = ceil( (f1_target − worse_metric) / 0.1 )   # 1 step per 0.1 deficit, min 1
```

### 5.4 Dimension-Specific Application

| Dimension | Threshold Type | TIGHTEN Action | LOOSEN Action | Config Target |
|-----------|----------------|----------------|---------------|---------------|
| **SkillOpt** | ruleset | Remove weak trigger keywords / add exclusion clauses | Add/broaden trigger keywords | `CLAUDE.md` Section 0 pattern table |
| **MultiAgentOpt** | numeric | Increase `PHASE1_TRIGGER` and `PHASE2_TRIGGER` by `magnitude` | Decrease them by `magnitude` (floor = 1) | `config/harness/multiagent-detect.sh` |
| **ToolCallOpt** | behavioral | Increase pattern strictness (e.g. mandate Read-before-Edit) | Relax strictness; allow more exploratory sequences | `config/harness/toolcall-track.sh` |

---

## 6. Integration with claude-mem-lite

### 6.1 Session-Level Granularity

The `session_logs` table in the claude-mem-lite SQLite database stores one row per session.  Enrich session metadata with a JSON blob (or separate columns) containing per-dimension counts:

```json
{
  "skillopt_tp": 1,    "skillopt_fp": 0,    "skillopt_fn": 0,
  "multiagent_tp": 0,  "multiagent_fp": 0,  "multiagent_fn": 0,
  "toolcall_tp": 2,    "toolcall_fp": 0,    "toolcall_fn": 1
}
```

This enables longitudinal SQL queries and per-session anomaly detection.

### 6.1.1 Session Count Unification (v2.2)

**Problem**: In v2.1, `meta.json.sessions` was incremented blindly by training-collect.py (a Stop hook that fires on every session), while the real session count lived in the claude-mem SQLite `session_logs` table (populated by auto-summary.py, which only the AI chooses to call).  These two counters were completely independent.

**Fix**: `training-collect.py` now queries the `session_logs` table for the true session count.  If the DB is unavailable, it falls back to the incremental counter.  This ensures `meta.json.sessions` reflects reality.

### 6.2 Feedback.md Parser Extension

`training-collect.sh` (Stop hook) parses `feedback.md` to populate `meta.json`.  Extend the parser to count the new headers:

| Feedback.md Header | Dimension | Count |
|-------------------|-----------|-------|
| `## SkillOpt > ### Correct Trigger` | skill | TP |
| `## SkillOpt > ### False Positive` | skill | FP |
| `## SkillOpt > ### Miss` | skill | FN |
| `## MultiAgentOpt > ### Correct Trigger` | multiagent | TP |
| `## MultiAgentOpt > ### False Positive` | multiagent | FP |
| `## MultiAgentOpt > ### Miss` | multiagent | FN |
| `## ToolCallOpt > ### Positive` | toolcall | TP |
| `## ToolCallOpt > ### Negative` | toolcall | FP |
| `## ToolCallOpt > ### Missed Opportunity` | toolcall | FN |

### 6.3 Exponential Weighting of Past Sessions

Past sessions are never discarded.  The EMA provides an infinitely decaying memory.  The harness does not need to keep a sliding window of raw session scores in memory; only the previous EMA values and the current aggregate counts are required.

---

## 7. Shared Metrics Module (v2.2)

### 7.1 Problem: Duplicate Logic

In v2.1, `training-collect.py` and `adaptive-threshold.py` each independently implemented ~60 lines of identical computation: `compute_metrics`, `compute_loss`, `update_ema`, `should_adjust`, `adjust_direction`, `adjust_magnitude`.  This resulted in:
- Bug fixes applied to one file but not the other
- Subtle behavioral divergence (e.g. `should_adjust` had slightly different signatures)
- EMA update rule differed between the two files

### 7.2 Solution: `metrics_core.py`

All shared computation lives in `config/training-loop/metrics_core.py`:
- `compute_metrics(counts)` — P/R/F1 with `has_data` flag
- `compute_loss(metrics, complexity, gamma)` — core loss + complexity penalty
- `update_ema(prev_ema, metrics, loss, lam, session_idx, prev_signal_count, current_signal_count)` — signal-count EMA
- `should_adjust(dim, global_cfg, sessions)` — adjustment gate with `adjustment_enabled` and `min_signals_for_adjustment`
- `adjust_direction(metrics)` — TIGHTEN/LOOSEN
- `adjust_magnitude(metrics, f1_target)` — integer step size
- `total_signal_count(counts)` — convenience for TP+FP+FN

Both `training-collect.py` and `adaptive-threshold.py` import from this module.  There is a fallback inline copy in `training-collect.py` for environments where the import path fails.

### 7.3 Complexity Penalty Instrumentation Stub (v2.2)

`C_current` was permanently zero in v2.1 because no code measured per-session invocation/dispatch/call counts.  The v2.2 refactoring adds an `activity` field per dimension in meta.json with keys like `skill_invocations`, `multiagent_dispatches`, `tool_calls`.  Both scripts now have the plumbing to accept these values.  Until harness instrumentation actually populates them (future work), `C_current` remains at 0.0.

---

## 8. Version Transition (v1 → v2.1 → v2.2)

Legacy `meta.json` (v1) stored:

| Legacy Path | v2.1 Mapping |
|-------------|--------------|
| `dimensions.skill.misses` | `dimensions.skill.counts.fn` |
| `dimensions.skill.false_positives` | `dimensions.skill.counts.fp` |
| `dimensions.multiagent.misses` | `dimensions.multiagent.counts.fn` |
| `dimensions.multiagent.false_positives` | `dimensions.multiagent.counts.fp` |
| `dimensions.toolcall.observations` | Split into `tp` and `fp` by counting `### Positive` vs `### Negative` in `feedback.md` |

Legacy `tp` values are initially `0` because v1 did not record positive outcomes.  Immediately after migration, **Precision and Recall will be 0** for dimensions that have any recorded errors.  This is mathematically correct — it reflects that only negative signals were collected.  To bootstrap useful metrics, begin logging:
- `### Correct Trigger` under `## SkillOpt` and `## MultiAgentOpt`
- `### Positive` under `## ToolCallOpt`

Whenever a skill fires correctly or a tool pattern is praised, record it.

### v2.1 → v2.2

| v2.1 Field | v2.2 Mapping |
|-------------|--------------|
| `global` (no `min_signals_for_adjustment`) | `global.min_signals_for_adjustment = 10` |
| `global` (no `adjustment_enabled`) | `global.adjustment_enabled = false` |
| `dimensions.*.metrics` (no `has_data`) | `dimensions.*.metrics.has_data = true/false` |
| `dimensions.*.ema` (no `last_signal_count`) | `dimensions.*.ema.last_signal_count = N` |
| `version = "2.1"` | `version = "2.2"` |

Migration is automatic: both `training-collect.py` and `adaptive-threshold.py` add the missing fields when reading v2.1 meta.json.
