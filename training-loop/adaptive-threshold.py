#!/usr/bin/env python3
"""
Adaptive Threshold Optimizer for TrainingLoop v2.2
Reads meta.json (ML metrics schema), computes precision/recall/F1/loss
via metrics_core shared module, and suggests or applies automatic
threshold adjustments.

Changes from v2.1:
  - Imports computation from metrics_core.py (fixes Problem 9: duplicate logic)
  - Signal-count EMA: EMA updates only when new signals arrive (fixes Problem 3)
  - Vacuous correctness fix: no data => P/R/F1=None, not 1.0 (fixes Problem 5)
  - min_signals_for_adjustment gates adjustment until sufficient data (fixes Problem 7)
  - adjustment_enabled flag in global config (fixes Problem 4)

Usage:
    python adaptive-threshold.py [--apply] [--meta PATH] [--dry-run]
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# --- import shared metrics ---
sys.path.insert(0, str(Path(__file__).resolve().parent))
try:
    from metrics_core import (
        compute_metrics,
        compute_loss,
        update_ema,
        should_adjust,
        adjust_direction,
        adjust_magnitude,
        total_signal_count,
    )
except ImportError:
    # Should not happen — metrics_core.py lives in the same directory
    print("ERROR: metrics_core.py not found. Ensure it is in training-loop/ with adaptive-threshold.py.", file=sys.stderr)
    sys.exit(1)


def resolve_ecosystem_root() -> Path:
    script = Path(__file__).resolve()
    parent = script.parent
    # claude-ecosystem: config/training-loop/adaptive-threshold.py → root is 3 levels up
    if parent.name == "training-loop" and parent.parent.name == "config":
        return parent.parent.parent
    # lean-hooks: training-loop/adaptive-threshold.py → root is 1 level up
    return parent.parent


def load_meta(path: Path) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def save_meta(path: Path, data: dict) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")


def apply_multiagent_adjustment(magnitude: int, direction: str, ecosystem: Path) -> bool:
    config_harness = ecosystem / "config" / "harness" / "multiagent-detect.sh"
    root_harness = ecosystem / "harness" / "multiagent-detect.sh"
    script_path = config_harness if config_harness.exists() else root_harness
    if not script_path.exists():
        return False

    content = script_path.read_text(encoding="utf-8")

    def replace_threshold(match: re.Match) -> str:
        name = match.group(1)
        old_val = int(match.group(2))
        if direction == "TIGHTEN":
            new_val = old_val + magnitude
        else:
            new_val = max(1, old_val - magnitude)
        return f'{name}={new_val}'

    new_content, count1 = re.subn(r'^(PHASE1_TRIGGER_MIN)=(\d+)$', replace_threshold, content, flags=re.MULTILINE)
    new_content, count2 = re.subn(r'^(PHASE2_TRIGGER_MIN)=(\d+)$', replace_threshold, new_content, flags=re.MULTILINE)

    if count1 or count2:
        script_path.write_text(new_content, encoding="utf-8")
        return True
    return False


def migrate_v1_to_v21(meta: dict) -> dict:
    """Convert legacy v1 meta.json to v2.2 schema."""
    if meta.get("version") in ("2.1", "2.2"):
        return meta

    dims_legacy = meta.get("dimensions", {})
    sessions = meta.get("sessions", 0)

    def migrate_dim(old: dict, defaults: dict) -> dict:
        tp = old.get("correct_triggers", 0)  # legacy may not have this
        fp = old.get("false_positives", 0)
        fn = old.get("misses", 0)
        # v1 didn't record TP; infer 0. User should start logging positives.
        if "observations" in old:
            # toolcall v1: observations lumped together; treat as unknown TP/FP
            tp = 0
            fp = old.get("observations", 0)
            fn = 0
        return {
            "counts": {"tp": tp, "fp": fp, "fn": fn},
            "metrics": {},
            "ema": {},
            "loss": {},
            "complexity": defaults.get("complexity", {"current": 0.0, "target": 1.0}),
            "threshold": old.get("threshold", 3),
            "threshold_config": defaults.get("threshold_config"),
            "last_adjusted_session": 0,
            "last_optimized": old.get("last_optimized", ""),
        }

    defaults = {
        "skill": {"complexity": {"current": 0.0, "target": 2.0}},
        "multiagent": {
            "complexity": {"current": 0.0, "target": 0.5},
            "threshold_config": {
                "current_value": 3,
                "min_value": 1,
                "max_value": 10,
                "config_file": str((resolve_ecosystem_root() / "harness" / "multiagent-detect.sh").resolve()),
                "config_pattern": "PHASE[12]_TRIGGER",
            },
        },
        "toolcall": {"complexity": {"current": 0.0, "target": 8.0}},
    }

    new_meta = {
        "version": "2.2",
        "sessions": sessions,
        "last_session": meta.get("last_session", datetime.now(timezone.utc).isoformat()),
        "last_optimized": meta.get("last_optimized", ""),
        "global": {
            "ema_lambda": 0.1818,
            "f1_target": 0.75,
            "min_adjust_interval": 3,
            "complexity_gamma": 0.15,
            "min_signals_for_adjustment": 10,
            "adjustment_enabled": False,
        },
        "dimensions": {},
    }

    for name in ["skill", "multiagent", "toolcall"]:
        old = dims_legacy.get(name, {})
        new_meta["dimensions"][name] = migrate_dim(old, defaults.get(name, {}))

    return new_meta


def run(meta_path: Path, apply: bool, dry_run: bool) -> int:
    if not meta_path.exists():
        print(f"ERROR: Meta file not found: {meta_path}", file=sys.stderr)
        return 1

    meta = load_meta(meta_path)
    meta = migrate_v1_to_v21(meta)

    global_cfg = meta.get("global", {})
    sessions = meta.get("sessions", 0)
    gamma = global_cfg.get("complexity_gamma", 0.15)
    lam = global_cfg.get("ema_lambda", 0.1818)
    f1_target = global_cfg.get("f1_target", 0.75)
    ecosystem = meta_path.parent.parent.parent

    # Ensure v2.2 global config fields
    global_cfg.setdefault("min_signals_for_adjustment", 10)
    global_cfg.setdefault("adjustment_enabled", False)
    meta["global"] = global_cfg

    any_adjusted = False
    report_lines = ["=" * 50, "Adaptive Threshold Report (v2.2)", "=" * 50, ""]

    if not global_cfg.get("adjustment_enabled", False):
        report_lines.append("NOTE: adjustment_enabled=false — system is in L0 (report-only) mode.")
        report_lines.append("  Automatic threshold adjustments are disabled until sufficient data is collected.")
        report_lines.append("")

    for dim_name in ["skill", "multiagent", "toolcall"]:
        dim = meta["dimensions"].setdefault(dim_name, {})
        counts = dim.setdefault("counts", {"tp": 0, "fp": 0, "fn": 0})
        metrics = compute_metrics(counts)
        dim["metrics"] = metrics

        complexity = dim.setdefault("complexity", {"current": 0.0, "target": 1.0})
        loss = compute_loss(metrics, complexity, gamma)
        dim["loss"] = loss

        # Signal-count EMA
        current_signals = total_signal_count(counts)
        prev_ema = dim.get("ema", {})
        prev_signal_count = prev_ema.get("last_signal_count", 0)
        ema = update_ema(prev_ema, metrics, loss, lam, sessions,
                         prev_signal_count=prev_signal_count,
                         current_signal_count=current_signals)
        dim["ema"] = ema

        has_data = metrics.get("has_data", True)

        report_lines.append(f"Dimension: {dim_name.upper()}")
        report_lines.append(f"  Counts      : TP={counts['tp']} FP={counts['fp']} FN={counts['fn']} (signals={current_signals})")
        if has_data:
            report_lines.append(f"  Precision   : {metrics['precision']:.4f}")
            report_lines.append(f"  Recall      : {metrics['recall']:.4f}")
            report_lines.append(f"  F1          : {metrics['f1']:.4f}")
        else:
            report_lines.append(f"  Metrics     : NO DATA (all counts zero)")
        if ema.get("f1") is not None:
            report_lines.append(f"  EMA F1      : {ema['f1']:.4f} (last updated session {ema.get('last_updated_session', '?')})")
        else:
            report_lines.append(f"  EMA F1      : N/A (no signals yet)")
        report_lines.append(f"  Loss (core) : {loss['core']:.4f}")
        report_lines.append(f"  Loss (total): {loss['total']:.4f}")

        if should_adjust(dim, global_cfg, sessions):
            direction = adjust_direction(metrics)
            magnitude = adjust_magnitude(metrics, f1_target)
            report_lines.append(f"  ADJUSTMENT TRIGGERED -> {direction} by {magnitude}")

            action_taken = False
            if dim_name == "multiagent":
                if apply and not dry_run:
                    action_taken = apply_multiagent_adjustment(magnitude, direction, ecosystem)
                else:
                    report_lines.append(f"  (dry-run: would change multiagent-detect.sh thresholds)")

            dim["last_adjusted_session"] = sessions
            note = f"{datetime.now(timezone.utc).isoformat()}: {direction} {magnitude} ({dim_name})"
            dim["last_optimized"] = note
            meta["last_optimized"] = note
            report_lines.append(f"  Action      : {'APPLIED' if action_taken else 'NOT APPLIED'}")
            any_adjusted = True
        else:
            # Explain why
            if not global_cfg.get("adjustment_enabled", False):
                report_lines.append(f"  Adjustment  : Disabled (adjustment_enabled=false)")
            elif current_signals < global_cfg.get("min_signals_for_adjustment", 10):
                report_lines.append(f"  Adjustment  : Insufficient signals ({current_signals}/{global_cfg.get('min_signals_for_adjustment', 10)})")
            elif not has_data:
                report_lines.append(f"  Adjustment  : No data (all counts zero)")
            elif ema.get("f1") is None:
                report_lines.append(f"  Adjustment  : EMA F1 unavailable")
            else:
                report_lines.append(f"  Adjustment  : Not triggered (EMA F1={ema['f1']:.4f} >= {f1_target} or interval)")

        report_lines.append("")

    report = "\n".join(report_lines)
    print(report)

    # Update version
    meta["version"] = "2.2"

    if apply and not dry_run:
        save_meta(meta_path, meta)
        print(f"[INFO] Updated meta.json written to {meta_path}")
    else:
        print("[INFO] Dry run — meta.json not modified. Pass --apply to persist changes.")

    return 0 if not any_adjusted or (apply and not dry_run) else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="TrainingLoop adaptive threshold optimizer v2.2")
    parser.add_argument("--meta", type=Path, default=None, help="Path to meta.json")
    parser.add_argument("--apply", action="store_true", help="Persist computed metrics and apply threshold adjustments")
    parser.add_argument("--dry-run", action="store_true", help="Show what would be done without writing files")
    args = parser.parse_args(argv)

    meta_path = args.meta or (resolve_ecosystem_root() / "training-loop" / "meta.json")
    return run(meta_path, args.apply, args.dry_run)


if __name__ == "__main__":
    sys.exit(main())
