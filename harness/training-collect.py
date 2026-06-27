#!/usr/bin/env python3
"""
Training Loop Collector v2.2 — Stop hook (unified)
Reads training-loop/feedback.md, counts TP/FP/FN per dimension,
computes precision/recall/F1/EMA/loss via metrics_core shared module,
updates meta.json.

Changes from v2.1:
  - Imports computation from metrics_core.py (fixes Problem 9: duplicate logic)
  - Signal-count EMA: EMA updates only when new signals arrive (fixes Problem 3)
  - Vacuous correctness fix: no data => P/R/F1=None, not 1.0 (fixes Problem 5)
  - min_signals_for_adjustment gates adjustment until sufficient data (fixes Problem 7)
  - adjustment_enabled flag in global config (fixes Problem 4)
  - Session count queried from claude-mem SQLite (fixes Problem 1)
  - C_current instrumentation stub (fixes Problem 6)

Usage:
    python training-collect.py [--apply-thresholds]
"""
import argparse
import json
import math
import os
import re
import sqlite3
import sys
from datetime import datetime, timezone
from pathlib import Path

# Ensure UTF-8 on Windows
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8")

# --- import shared metrics ---
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "training-loop"))
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
    # Fallback: inline the functions if metrics_core is missing
    EPS = 1e-8

    def compute_metrics(counts):
        tp, fp, fn = counts["tp"], counts["fp"], counts["fn"]
        if tp == fp == fn == 0:
            return {"precision": None, "recall": None, "f1": None, "has_data": False}
        precision = tp / (tp + fp + EPS)
        recall = tp / (tp + fn + EPS)
        f1 = 2 * precision * recall / (precision + recall + EPS)
        return {"precision": precision, "recall": recall, "f1": f1, "has_data": True}

    def compute_loss(metrics, complexity, gamma):
        if not metrics.get("has_data", True):
            return {"core": 0.0, "complexity_penalty": 0.0, "total": 0.0}
        p, r = metrics["precision"], metrics["recall"]
        omp, omr = 1 - p, 1 - r
        denom = omp + omr + EPS
        l_core = (omp ** 2 + omr ** 2) / denom
        c_current = complexity.get("current", 0.0)
        c_target = complexity.get("target", 1.0)
        c_norm = max(0.0, (c_current - c_target) / (c_target + EPS))
        l_complexity = gamma * c_norm
        return {"core": l_core, "complexity_penalty": l_complexity, "total": l_core + l_complexity}

    def update_ema(prev_ema, metrics, loss, lam, session_idx,
                   prev_signal_count=0, current_signal_count=0):
        if not metrics.get("has_data", True):
            prev = prev_ema or {}
            return {"precision": prev.get("precision"), "recall": prev.get("recall"),
                    "f1": prev.get("f1"), "loss": prev.get("loss"),
                    "last_updated_session": prev.get("last_updated_session", 0),
                    "last_signal_count": prev_signal_count}
        if current_signal_count <= prev_signal_count:
            prev = prev_ema or {}
            return {"precision": prev.get("precision"), "recall": prev.get("recall"),
                    "f1": prev.get("f1"), "loss": prev.get("loss"),
                    "last_updated_session": prev.get("last_updated_session", 0),
                    "last_signal_count": prev_signal_count}
        def ema_val(old, new):
            if old is None or new is None:
                return new
            return lam * new + (1 - lam) * old
        prev = prev_ema or {}
        return {"precision": ema_val(prev.get("precision"), metrics["precision"]),
                "recall": ema_val(prev.get("recall"), metrics["recall"]),
                "f1": ema_val(prev.get("f1"), metrics["f1"]),
                "loss": ema_val(prev.get("loss"), loss["total"]),
                "last_updated_session": session_idx,
                "last_signal_count": current_signal_count}

    def should_adjust(dim, global_cfg, sessions):
        if not global_cfg.get("adjustment_enabled", False):
            return False
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

    def adjust_direction(metrics):
        p = metrics.get("precision")
        r = metrics.get("recall")
        if p is None or r is None:
            return "LOOSEN"
        return "TIGHTEN" if p < r else "LOOSEN"

    def adjust_magnitude(metrics, f1_target):
        p = metrics.get("precision")
        r = metrics.get("recall")
        if p is None or r is None:
            return 1
        worse = min(p, r)
        deficit = f1_target - worse
        return max(1, math.ceil(deficit / 0.1))

    def total_signal_count(counts):
        return counts.get("tp", 0) + counts.get("fp", 0) + counts.get("fn", 0)

# --- path resolution (dual-layout: config/training-loop/ or training-loop/) ---
SCRIPT_DIR = Path(__file__).resolve().parent
HARNESS_ROOT = Path(os.environ.get("HARNESS_ROOT", str(SCRIPT_DIR.parent))).resolve()

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
MIN_SIGNALS_FOR_ADJUSTMENT = 10

COMPLEXITY_DEFAULTS = {
    "skill": {"target": 2.0},
    "multiagent": {"target": 0.5},
    "toolcall": {"target": 8.0},
}

# Per-dimension activity counters for C_current stub
ACTIVITY_KEYS = {
    "skill": "skill_invocations",
    "multiagent": "multiagent_dispatches",
    "toolcall": "tool_calls",
}


def load_json(p: Path) -> dict:
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}


def save_json(p: Path, d: dict) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def get_session_count_from_db() -> int | None:
    """Query claude-mem SQLite for the real session count.

    Returns None if DB is unavailable (caller should fall back to counter).
    """
    # Auto-detect DB path
    data_dir = os.environ.get("CLAUDE_MEM_DATA_DIR")
    if data_dir:
        db_path = Path(data_dir) / "claude-mem.db"
    else:
        db_path = HARNESS_ROOT / "data" / "claude-mem" / "claude-mem.db"

    if not db_path.exists():
        return None

    try:
        conn = sqlite3.connect(str(db_path))
        cur = conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='session_logs'"
        )
        if not cur.fetchone():
            conn.close()
            return None
        cur = conn.execute("SELECT COUNT(*) FROM session_logs")
        row = cur.fetchone()
        conn.close()
        return row[0] if row else None
    except Exception:
        return None


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


def adjust_multiagent_config(magnitude: int, direction: str) -> bool:
    # Try claude-ecosystem layout first, then lean-hooks
    script = HARNESS_ROOT / "config" / "harness" / "multiagent-detect.sh"
    if not script.exists():
        script = HARNESS_ROOT / "harness" / "multiagent-detect.sh"
    if not script.exists():
        return False

    def replace(m: re.Match) -> str:
        old = int(m.group(2))
        new = old + magnitude if direction == "TIGHTEN" else max(1, old - magnitude)
        return f'{m.group(1)}={new}'

    try:
        text = script.read_text(encoding="utf-8")
        # Only replace the bash variable declarations at start of line (not Python usages)
        new_text, count1 = re.subn(r'^(PHASE1_TRIGGER_MIN)=(\d+)$', replace, text, flags=re.MULTILINE)
        new_text, count2 = re.subn(r'^(PHASE2_TRIGGER_MIN)=(\d+)$', replace, new_text, flags=re.MULTILINE)
        if count1 or count2:
            script.write_text(new_text, encoding="utf-8")
            return True
    except OSError:
        pass
    return False


def migrate_v1_to_v21(meta: dict) -> dict:
    if meta.get("version") in ("2.1", "2.2"):
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
        "version": "2.2",
        "sessions": sessions,
        "last_session": meta.get("last_session", datetime.now(timezone.utc).isoformat()),
        "last_optimized": meta.get("last_optimized", ""),
        "global": {
            "ema_lambda": EMA_LAMBDA_DEFAULT,
            "f1_target": F1_TARGET_DEFAULT,
            "min_adjust_interval": MIN_ADJUST_INTERVAL,
            "complexity_gamma": GAMMA_DEFAULT,
            "min_signals_for_adjustment": MIN_SIGNALS_FOR_ADJUSTMENT,
            "adjustment_enabled": False,
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


def _run_skill_attention_feedback(feedback_text: str) -> None:
    """Parse [skill:NAME] and [prompt:"..."] tags from SkillOpt section,
    call skill-attention.py feedback for each entry."""
    import subprocess

    # Extract SkillOpt block
    block_re = r"^##\s+SkillOpt.*?(?=^##[^#]|\Z)"
    m = re.search(block_re, feedback_text, re.MULTILINE | re.DOTALL | re.IGNORECASE)
    if not m:
        return
    block = m.group(0)

    # Find all entries: ### (Correct Trigger|Miss|False Positive) with [skill:NAME] [prompt:"..."]
    sa_script = HARNESS_ROOT / "config" / "harness" / "skill-attention.py"
    if not sa_script.exists():
        sa_script = HARNESS_ROOT / "harness" / "skill-attention.py"
    if not sa_script.exists():
        return

    signal_map = {
        "Correct Trigger": "correct",
        "Miss": "miss",
        "False Positive": "fp",
    }

    py_exe = os.environ.get("HARNESS_PYTHON", sys.executable)

    for label, signal in signal_map.items():
        # Find lines under each ### subsection
        sec_re = rf"^###\s+{re.escape(label)}.*?(?=^###|^##|\Z)"
        sec_m = re.search(sec_re, block, re.MULTILINE | re.DOTALL)
        if not sec_m:
            continue
        sec_text = sec_m.group(0)
        # Extract [skill:NAME] and [prompt:"..."] pairs
        for entry in re.finditer(
            r'\[skill:([^\]]+)\]\s*\[prompt:"([^"]*)"\]',
            sec_text,
        ):
            skill = entry.group(1).strip()
            prompt = entry.group(2).strip()
            if skill and prompt:
                try:
                    subprocess.run(
                        [py_exe, str(sa_script), "feedback",
                         "--skill", skill, "--signal", signal,
                         "--prompt", prompt],
                        capture_output=True, timeout=30,
                    )
                except Exception:
                    pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Training Loop Collector v2.2")
    parser.add_argument("--apply-thresholds", action="store_true", help="Apply threshold adjustments to config files")
    parser.add_argument("--meta", type=Path, default=META, help="Path to meta.json")
    args = parser.parse_args(argv)

    ensure_feedback_md()
    meta = load_json(args.meta)
    meta = migrate_v1_to_v21(meta)

    # --- Session count from SQLite (Problem 1 fix) ---
    db_session_count = get_session_count_from_db()
    if db_session_count is not None:
        # Use real session count from DB
        sessions = db_session_count
    else:
        # Fallback: increment counter
        sessions = meta.get("sessions", 0) + 1
    meta["sessions"] = sessions
    meta["last_session"] = datetime.now(timezone.utc).isoformat()

    # Ensure global config has new v2.2 fields
    global_cfg = meta.setdefault("global", {})
    global_cfg.setdefault("min_signals_for_adjustment", MIN_SIGNALS_FOR_ADJUSTMENT)
    global_cfg.setdefault("adjustment_enabled", False)
    meta["global"] = global_cfg

    feedback_text = FEEDBACK.read_text(encoding="utf-8") if FEEDBACK.exists() else ""

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

        # --- Signal-count EMA (Problem 3 fix) ---
        current_signals = total_signal_count(counts)
        prev_ema = dim.get("ema", {})
        prev_signal_count = prev_ema.get("last_signal_count", 0)
        ema = update_ema(prev_ema, metrics, loss, lam, sessions,
                         prev_signal_count=prev_signal_count,
                         current_signal_count=current_signals)
        dim["ema"] = ema

        # --- C_current instrumentation stub (Problem 6) ---
        # The plumbing exists: training-collect records per-dimension activity.
        # Actual counting requires harness instrumentation; for now current stays 0.
        if "activity" not in dim:
            dim["activity"] = {k: 0 for k in ACTIVITY_KEYS.values()}

        # --- Output ---
        has_data = metrics.get("has_data", True)
        if has_data:
            line = (
                f"[{section_name}] TP={counts['tp']} FP={counts['fp']} FN={counts['fn']} "
                f"P={metrics['precision']:.3f} R={metrics['recall']:.3f} F1={metrics['f1']:.3f} "
                f"EMA(F1)={ema['f1']:.3f} L={loss['total']:.3f} "
                f"signals={current_signals}"
            )
        else:
            line = (
                f"[{section_name}] TP=0 FP=0 FN=0 NO_DATA "
                f"EMA(F1)={ema['f1']:.3f if ema.get('f1') is not None else 'N/A'} "
                f"signals=0"
            )
        print(line)

        # Only alert when we have data and metrics are below target
        if has_data and (metrics["f1"] < f1_target or (ema.get("f1") is not None and ema["f1"] < f1_target)):
            alerts.append(line)

        # --- Adjustment decision ---
        if should_adjust(dim, global_cfg, sessions):
            direction = adjust_direction(metrics)
            magnitude = adjust_magnitude(metrics, f1_target)
            print(f"  -> ADJUSTMENT: {direction} by {magnitude}")

            applied = False
            if dim_name == "multiagent" and args.apply_thresholds:
                applied = adjust_multiagent_config(magnitude, direction)
                adjusted_any = applied

            dim["last_adjusted_session"] = sessions
            note = f"{datetime.now(timezone.utc).isoformat()}: {direction} {magnitude}"
            dim["last_optimized"] = note
            meta["last_optimized"] = note
        else:
            # Log why adjustment was skipped
            if not global_cfg.get("adjustment_enabled", False):
                print(f"  -> adjustment: disabled (adjustment_enabled=false)")
            elif total_signal_count(counts) < global_cfg.get("min_signals_for_adjustment", MIN_SIGNALS_FOR_ADJUSTMENT):
                print(f"  -> adjustment: insufficient signals ({current_signals}/{global_cfg.get('min_signals_for_adjustment', MIN_SIGNALS_FOR_ADJUSTMENT)})")
            elif not has_data:
                print(f"  -> adjustment: no data")
            elif ema.get("f1") is None:
                print(f"  -> adjustment: EMA F1 unavailable")
            else:
                print(f"  -> adjustment: not triggered (EMA F1={ema['f1']:.4f} >= {f1_target} or interval)")

    # Update version
    meta["version"] = "2.2"

    save_json(args.meta, meta)

    # --- Skill Attention feedback integration ---
    if args.apply_thresholds:
        try:
            _run_skill_attention_feedback(feedback_text)
        except Exception as e:
            print(f"[TrainingLoop] skill-attention feedback skipped: {e}", file=sys.stderr)

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
    if not global_cfg.get("adjustment_enabled", False):
        total_all = sum(
            total_signal_count(meta.get("dimensions", {}).get(d, {}).get("counts", {}))
            for d in ["skill", "multiagent", "toolcall"]
        )
        print(f"  [L0] adjustment_enabled=false — 系统处于报告模式 (total signals={total_all}, need >=50 for auto-adjust)", file=sys.stderr)
    print("  正/负样本均可记录，积累后自动计算指标并触发调整。", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
