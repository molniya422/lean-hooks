#!/usr/bin/env python3
"""
Shared metrics computation for TrainingLoop v2.2.

Eliminates ~60 lines of duplicate logic between training-collect.py and
adaptive-threshold.py.  Also fixes:

  - EMA applied to cumulative metrics (Problem 3):
    EMA now updates only when new signals arrive (signal-count EMA).
    ``last_signal_count`` in meta.json tracks the count at last EMA update.
  - Vacuous correctness bias (Problem 5):
    When TP=FP=FN=0, compute_metrics returns has_data=False and all None
    values instead of P=R=F1=1.0.  Callers must check has_data before
    using the metrics.
  - Statistical significance gating (Problem 7):
    ``min_signals_for_adjustment`` (default=10) prevents threshold
    adjustment when total signals are below this threshold.
  - Adjustment kill-switch (Problem 4/7):
    ``adjustment_enabled`` (default=false) in global config disables
    auto-adjustment until the system has sufficient data.
"""

import math

EPS = 1e-8


def compute_metrics(counts: dict) -> dict:
    """Compute precision/recall/F1 from confusion-matrix counts.

    Returns dict with keys: precision, recall, f1, has_data.
    When TP=FP=FN=0 (no data), returns has_data=False and all metrics
    are None instead of the vacuous P=R=F1=1.0.
    """
    tp = counts.get("tp", 0)
    fp = counts.get("fp", 0)
    fn = counts.get("fn", 0)

    if tp == fp == fn == 0:
        return {"precision": None, "recall": None, "f1": None, "has_data": False}

    precision = tp / (tp + fp + EPS)
    recall = tp / (tp + fn + EPS)
    f1 = 2 * precision * recall / (precision + recall + EPS)
    return {"precision": precision, "recall": recall, "f1": f1, "has_data": True}


def compute_loss(metrics: dict, complexity: dict, gamma: float) -> dict:
    """Compute adaptive core loss + complexity penalty.

    When metrics has no data (has_data=False), returns zero loss.
    """
    if not metrics.get("has_data", True):
        return {"core": 0.0, "complexity_penalty": 0.0, "total": 0.0}

    p = metrics["precision"]
    r = metrics["recall"]
    omp = 1 - p
    omr = 1 - r
    denom = omp + omr + EPS
    l_core = (omp ** 2 + omr ** 2) / denom

    c_current = complexity.get("current", 0.0)
    c_target = complexity.get("target", 1.0)
    c_norm = max(0.0, (c_current - c_target) / (c_target + EPS))
    l_complexity = gamma * c_norm

    return {
        "core": l_core,
        "complexity_penalty": l_complexity,
        "total": l_core + l_complexity,
    }


def update_ema(prev_ema: dict | None, metrics: dict, loss: dict,
               lam: float, session_idx: int,
               prev_signal_count: int = 0, current_signal_count: int = 0) -> dict:
    """Signal-count EMA: only update when new signals have arrived.

    If current_signal_count <= prev_signal_count, the EMA is unchanged
    (no new signal to learn from).  This prevents the same cumulative
    metric from being re-smoothed 386 times across sessions with no
    new data.

    When metrics has no data (has_data=False), EMA is not updated.
    """
    # No data -> skip EMA update entirely
    if not metrics.get("has_data", True):
        prev = prev_ema or {}
        return {
            "precision": prev.get("precision"),
            "recall": prev.get("recall"),
            "f1": prev.get("f1"),
            "loss": prev.get("loss"),
            "last_updated_session": prev.get("last_updated_session", 0),
            "last_signal_count": prev_signal_count,
        }

    # No new signals -> keep previous EMA unchanged
    if current_signal_count <= prev_signal_count:
        prev = prev_ema or {}
        return {
            "precision": prev.get("precision"),
            "recall": prev.get("recall"),
            "f1": prev.get("f1"),
            "loss": prev.get("loss"),
            "last_updated_session": prev.get("last_updated_session", 0),
            "last_signal_count": prev_signal_count,
        }

    # New signals arrived: apply EMA to current point metrics
    def ema_val(old, new):
        if old is None or new is None:
            return new
        return lam * new + (1 - lam) * old

    prev = prev_ema or {}
    return {
        "precision": ema_val(prev.get("precision"), metrics["precision"]),
        "recall": ema_val(prev.get("recall"), metrics["recall"]),
        "f1": ema_val(prev.get("f1"), metrics["f1"]),
        "loss": ema_val(prev.get("loss"), loss["total"]),
        "last_updated_session": session_idx,
        "last_signal_count": current_signal_count,
    }


def should_adjust(dim: dict, global_cfg: dict, sessions: int) -> bool:
    """Decide whether automatic threshold adjustment should fire.

    Checks:
      1. adjustment_enabled (global flag, default=false)
      2. Total signals (tp+fp+fn) >= min_signals_for_adjustment (default=10)
      3. EMA F1 exists and is below f1_target
      4. Session interval since last adjustment >= min_adjust_interval
    """
    # Check adjustment_enabled
    if not global_cfg.get("adjustment_enabled", False):
        return False

    # Check minimum signals for statistical significance
    counts = dim.get("counts", {})
    total_signals = counts.get("tp", 0) + counts.get("fp", 0) + counts.get("fn", 0)
    min_signals = global_cfg.get("min_signals_for_adjustment", 10)
    if total_signals < min_signals:
        return False

    ema = dim.get("ema", {})
    f1 = ema.get("f1")
    if f1 is None:
        return False

    target = global_cfg.get("f1_target", 0.75)
    interval = global_cfg.get("min_adjust_interval", 3)
    last = dim.get("last_adjusted_session", 0)

    return f1 < target and (sessions - last) >= interval


def adjust_direction(metrics: dict) -> str:
    """Return TIGHTEN if precision < recall, else LOOSEN.

    Requires has_data=True metrics with non-None precision/recall.
    """
    p = metrics.get("precision")
    r = metrics.get("recall")
    if p is None or r is None:
        return "LOOSEN"  # safe default when no data
    return "TIGHTEN" if p < r else "LOOSEN"


def adjust_magnitude(metrics: dict, f1_target: float) -> int:
    """Compute adjustment magnitude from the worse metric's deficit.

    Returns at least 1.
    """
    p = metrics.get("precision")
    r = metrics.get("recall")
    if p is None or r is None:
        return 1  # minimum magnitude when data unavailable
    worse = min(p, r)
    deficit = f1_target - worse
    return max(1, math.ceil(deficit / 0.1))


def total_signal_count(counts: dict) -> int:
    """Sum of TP+FP+FN for a dimension."""
    return counts.get("tp", 0) + counts.get("fp", 0) + counts.get("fn", 0)
