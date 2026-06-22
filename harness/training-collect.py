#!/usr/bin/env python3
"""
Training Loop Collector v2.1 — Stop hook (unified)
Reads training-loop/feedback.md, counts TP/FP/FN per dimension,
computes precision/recall/F1/EMA/loss, updates meta.json.

Usage:
    python training-collect.py [--apply-thresholds]
"""
import argparse
import json
import math
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

# Ensure UTF-8 on Windows
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

EPS = 1e-8

# --- path resolution (dual-layout: config/training-loop/ or training-loop/) ---
SCRIPT_DIR = Path(__file__).resolve().parent
HARNESS_ROOT = Path(os.environ.get("HARNESS_ROOT", SCRIPT_DIR.parent)).resolve()

# Try claude-ecosystem layout first (config/training-loop/), then lean-hooks (training-loop/)
_loop_legacy = HARNESS_ROOT / "training-loop"
_loop_config = HARNESS_ROOT / "config" / "training-loop"
LOOP_DIR = _loop_config if _loop_config.exists() else _loop_legacy
META = LOOP_DIR / "meta.json"
FEEDBACK = LOOP_DIR / "feedback.md"

# --- defaults ---
F1_TARGET_DEFAULT = 0.75
MIN_ADJUST_INTERVAL = 3
EMA_LAMBDA_DEFAULT = 0.1818  # 2/(10+1)
GAMMA_DEFAULT = 0.15

COMPLEXITY_DEFAULTS = {
    "skill": {"target": 2.0},
    "multiagent": {"target": 0.5},
    "toolcall": {"target": 8.0},
}


def load_json(p: Path) -> dict:
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}


def save_json(p: Path, d: dict) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def ensure_feedback_md() -> None:
    if FEEDBACK.exists():
        return
    LOOP_DIR.mkdir(parents=True, exist_ok=True)
    FEEDBACK.write_text(
        "# Training Loop Feedback\n\n"
        "## SkillOpt — Skill Trigger Accuracy\n### Correct Trigger\n### Miss\n### False Positive\n\n"
        "## MultiAgentOpt — Agent Dispatch Accuracy\n### Correct Trigger\n### Miss\n### False Positive\n\n"
        "## ToolCallOpt — Tool Call Pattern Quality\n### Positive\n### Missed Opportunity\n### Negative\n",
        encoding="utf-8",
    )


def count_entries(text: str, dim: str, labels: dict[str, str]) -> dict[str, int]:
    """Count occurrences under a specific ## section heading."""
    # Extract the section block for this dimension
    block_re = rf"^##\s+{re.escape(dim)}.*?(?=^##[^#]|\Z)"
    m = re.search(block_re, text, re.MULTILINE | re.DOTALL | re.IGNORECASE)
    block = m.group(0) if m else ""
    counts = {}
    for key, label in labels.items():
        # Match lines like ### Correct Trigger (allow extra suffix text)
        pat = rf"^###\s+{re.escape(label)}(?:\s+.+|$)"
        counts[key] = len(re.findall(pat, block, re.MULTILINE))
    return counts


def compute_metrics(counts: dict) -> dict:
    tp, fp, fn = counts["tp"], counts["fp"], counts["fn"]
    if tp == fp == fn == 0:
        return {"precision": 1.0, "recall": 1.0, "f1": 1.0}
    precision = tp / (tp + fp + EPS)
    recall = tp / (tp + fn + EPS)
    f1 = 2 * precision * recall / (precision + recall + EPS)
    return {"precision": precision, "recall": recall, "f1": f1}


def compute_loss(metrics: dict, complexity: dict, gamma: float) -> dict:
    p, r = metrics["precision"], metrics["recall"]
    omp, omr = 1 - p, 1 - r
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


def update_ema(old: dict | None, metrics: dict, loss: dict, lam: float) -> dict:
    def ema_val(prev, new):
        return new if prev is None else lam * new + (1 - lam) * prev

    prev = old or {}
    return {
        "precision": ema_val(prev.get("precision"), metrics["precision"]),
        "recall": ema_val(prev.get("recall"), metrics["recall"]),
        "f1": ema_val(prev.get("f1"), metrics["f1"]),
        "loss": ema_val(prev.get("loss"), loss["total"]),
        "last_updated_session": metrics.get("_session_idx", prev.get("last_updated_session", 0)),
    }


def should_adjust(dim: dict, global_cfg: dict, sessions: int) -> bool:
    ema = dim.get("ema", {})
    f1 = ema.get("f1")
    if f1 is None:
        return False
    target = global_cfg.get("f1_target", F1_TARGET_DEFAULT)
    interval = global_cfg.get("min_adjust_interval", MIN_ADJUST_INTERVAL)
    last = dim.get("last_adjusted_session", 0)
    return f1 < target and (sessions - last) >= interval


def adjust_multiagent_config(magnitude: int, direction: str) -> bool:
    # Try claude-ecosystem layout first, then lean-hooks
    script = HARNESS_ROOT / "config" / "harness" / "multiagent-detect.sh"
    if not script.exists():
        script = HARNESS_ROOT / "harness" / "multiagent-detect.sh"
    if not script.exists():
        return False
    text = script.read_text(encoding="utf-8")

    def replace(m: re.Match) -> str:
        old = int(m.group(2))
        new = old + magnitude if direction == "TIGHTEN" else max(1, old - magnitude)
        return f'{m.group(1)}="{new}"'

    new_text, count1 = re.subn(r'(PHASE1_TRIGGER_MIN)="(\d+)"', replace, text)
    new_text, count2 = re.subn(r'(PHASE2_TRIGGER_MIN)="(\d+)"', replace, new_text)
    if count1 or count2:
        script.write_text(new_text, encoding="utf-8")
        return True
    return False


def migrate_v1_to_v21(meta: dict) -> dict:
    if meta.get("version") == "2.1":
        return meta
    dims_legacy = meta.get("dimensions", {})
    sessions = meta.get("sessions", 0)

    def migrate_dim(old: dict, dim_name: str) -> dict:
        if "counts" in old:
            return old  # already v21
        fp = old.get("false_positives", 0)
        fn = old.get("misses", 0)
        tp = old.get("correct_triggers", 0)
        if "observations" in old:
            # Legacy v1 "observations" count: prefer correct_triggers if available
            if "correct_triggers" in old:
                tp = old["correct_triggers"]
                fp = max(0, old.get("observations", 0) - tp)
            else:
                tp = 0
                fp = old.get("observations", 0)
        defaults = COMPLEXITY_DEFAULTS.get(dim_name, {"target": 1.0})
        return {
            "counts": {"tp": tp, "fp": fp, "fn": fn},
            "metrics": {},
            "ema": {},
            "loss": {},
            "complexity": {"current": 0.0, "target": defaults["target"]},
            "threshold": old.get("threshold", 3),
            "last_adjusted_session": 0,
            "last_optimized": old.get("last_optimized", ""),
        }

    new_meta = {
        "version": "2.1",
        "sessions": sessions,
        "last_session": meta.get("last_session", datetime.now(timezone.utc).isoformat()),
        "last_optimized": meta.get("last_optimized", ""),
        "global": {
            "ema_lambda": EMA_LAMBDA_DEFAULT,
            "f1_target": F1_TARGET_DEFAULT,
            "min_adjust_interval": MIN_ADJUST_INTERVAL,
            "complexity_gamma": GAMMA_DEFAULT,
        },
        "dimensions": {
            "skill": migrate_dim(dims_legacy.get("skill", {}), "skill"),
            "multiagent": migrate_dim(dims_legacy.get("multiagent", {}), "multiagent"),
            "toolcall": migrate_dim(dims_legacy.get("toolcall", {}), "toolcall"),
        },
    }
    # Preserve threshold_config if present
    for name in ("multiagent",):
        tc = dims_legacy.get(name, {}).get("threshold_config")
        if tc:
            new_meta["dimensions"][name]["threshold_config"] = tc
    return new_meta


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Training Loop Collector v2.1")
    parser.add_argument("--apply-thresholds", action="store_true", help="Apply threshold adjustments to config files")
    parser.add_argument("--meta", type=Path, default=META, help="Path to meta.json")
    args = parser.parse_args(argv)

    ensure_feedback_md()
    meta = load_json(args.meta)
    meta = migrate_v1_to_v21(meta)

    sessions = meta.get("sessions", 0) + 1
    meta["sessions"] = sessions
    meta["last_session"] = datetime.now(timezone.utc).isoformat()

    feedback_text = FEEDBACK.read_text(encoding="utf-8") if FEEDBACK.exists() else ""

    global_cfg = meta.get("global", {})
    lam = global_cfg.get("ema_lambda", EMA_LAMBDA_DEFAULT)
    gamma = global_cfg.get("complexity_gamma", GAMMA_DEFAULT)
    f1_target = global_cfg.get("f1_target", F1_TARGET_DEFAULT)

    alerts = []
    adjusted_any = False

    DIM_LABELS = {
        "skill": {"tp": "Correct Trigger", "fp": "False Positive", "fn": "Miss"},
        "multiagent": {"tp": "Correct Trigger", "fp": "False Positive", "fn": "Miss"},
        "toolcall": {"tp": "Positive", "fp": "Negative", "fn": "Missed Opportunity"},
    }

    for dim_name in ["skill", "multiagent", "toolcall"]:
        dim = meta["dimensions"].setdefault(dim_name, {})
        section_name = {
            "skill": "SkillOpt",
            "multiagent": "MultiAgentOpt",
            "toolcall": "ToolCallOpt",
        }[dim_name]

        labels = DIM_LABELS[dim_name]
        counts = count_entries(feedback_text, section_name, labels)
        dim["counts"] = counts

        metrics = compute_metrics(counts)
        dim["metrics"] = metrics

        complexity = dim.setdefault("complexity", {"current": 0.0, "target": COMPLEXITY_DEFAULTS[dim_name]["target"]})
        loss = compute_loss(metrics, complexity, gamma)
        dim["loss"] = loss

        ema = update_ema(dim.get("ema"), {**metrics, "_session_idx": sessions}, loss, lam)
        dim["ema"] = ema

        line = (
            f"[{section_name}] TP={counts['tp']} FP={counts['fp']} FN={counts['fn']} "
            f"P={metrics['precision']:.3f} R={metrics['recall']:.3f} F1={metrics['f1']:.3f} "
            f"EMA(F1)={ema['f1']:.3f} L={loss['total']:.3f}"
        )
        print(line)
        if metrics["f1"] < f1_target or ema.get("f1", 1.0) < f1_target:
            alerts.append(line)

        if should_adjust(dim, global_cfg, sessions):
            direction = "TIGHTEN" if metrics["precision"] < metrics["recall"] else "LOOSEN"
            worse = min(metrics["precision"], metrics["recall"])
            magnitude = max(1, math.ceil((f1_target - worse) / 0.1))
            print(f"  -> ADJUSTMENT: {direction} by {magnitude}")

            applied = False
            if dim_name == "multiagent" and args.apply_thresholds:
                applied = adjust_multiagent_config(magnitude, direction)
                adjusted_any = applied

            dim["last_adjusted_session"] = sessions
            note = f"{datetime.now(timezone.utc).isoformat()}: {direction} {magnitude}"
            dim["last_optimized"] = note
            meta["last_optimized"] = note

    save_json(args.meta, meta)

    # --- stderr alerts for SessionStart injection ---
    if alerts:
        print("[TrainingLoop] 阈值告警 (F1 < {:.2f}):".format(f1_target), file=sys.stderr)
        for a in alerts:
            print("  " + a, file=sys.stderr)
        print(file=sys.stderr)
        print("  反馈入口: training-loop/feedback.md (按 ## SkillOpt / ## MultiAgentOpt / ## ToolCallOpt 分区)", file=sys.stderr)
        print("  运行: python training-collect.py --apply-thresholds 可自动调整阈值", file=sys.stderr)

    # --- session-end reflection prompt ---
    print(file=sys.stderr)
    print("[TrainingLoop] 本轮行为质量反思:", file=sys.stderr)
    print("  SkillOpt : skill 触发是否准确? -> feedback.md ## SkillOpt > ### Correct Trigger / ### Miss / ### False Positive", file=sys.stderr)
    print("  MultiAgentOpt: agent 分发是否恰当? -> ## MultiAgentOpt > 同上", file=sys.stderr)
    print("  ToolCallOpt: 工具调用效率如何? -> ## ToolCallOpt > ### Positive / ### Missed Opportunity / ### Negative", file=sys.stderr)
    print("  正/负样本均可记录，积累后自动计算指标并触发调整。", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
