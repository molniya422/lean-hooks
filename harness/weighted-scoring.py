#!/usr/bin/env python3
"""
Weighted Scoring Engine for lean-hooks TrainingLoop.

Enhances the v2.1 metrics with:
  - Per-sample weights (correct triggers weigh more than misses)
  - Confidence scoring (recent observations > old ones)
  - Historical trend analysis (direction of improvement)
  - Auto-tuning recommendations based on historical data

Usage:
    python weighted-scoring.py [--feedback FEEDBACK.md] [--meta META.json]
    python weighted-scoring.py --recommend   # print tuning recommendations
"""

import json
import math
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

EPS = 1e-8

# --- Weights ---
# These define how much each observation type counts toward the score
WEIGHTS = {
    "skill": {
        "Correct Trigger": 1.0,
        "Miss": -0.8,
        "False Positive": -0.6,
    },
    "multiagent": {
        "Correct Trigger": 1.0,
        "Miss": -0.9,
        "False Positive": -0.7,
    },
    "toolcall": {
        "Positive": 0.5,
        "Missed Opportunity": -0.4,
        "Negative": -0.5,
    },
}

# Time decay: older observations count less
# Half-life in sessions: an observation from N sessions ago counts 50%
HALF_LIFE_SESSIONS = 10


def load_json(p: Path) -> dict:
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}


def save_json(p: Path, d: dict) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(d, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def count_weighted_entries(text: str, dim_label: str, labels: dict[str, float],
                           current_session: int, history: list[dict] | None = None) -> dict:
    """
    Count entries under a ## section with time decay weights.
    Returns weighted sums and raw counts.
    """
    block_re = rf"^##\s+{re.escape(dim_label)}.*?(?=^##[^#]|\Z)"
    m = re.search(block_re, text, re.MULTILINE | re.DOTALL | re.IGNORECASE)
    block = m.group(0) if m else ""

    weighted = {}
    raw = {}

    for key, weight in labels.items():
        pat = rf"^###\s+{re.escape(key)}(?:\s+.+|$)"
        matches = re.findall(pat, block, re.MULTILINE)
        count = len(matches)
        raw[key] = count

        # Apply time decay if history available
        if history and count > 0:
            # Estimate session distance: assume latest entries are recent
            total_weight = 0.0
            for i in range(count):
                session_dist = max(0, current_session - (len(history) - count + i))
                decay = 0.5 ** (session_dist / HALF_LIFE_SESSIONS)
                total_weight += weight * decay
            weighted[key] = total_weight
        else:
            weighted[key] = weight * count

    return {
        "raw": raw,
        "weighted": weighted,
        "total_weighted": sum(weighted.values()),
    }


def compute_weighted_f1(weighted: dict) -> dict:
    """Compute F1 from weighted TP/FP/FN values."""
    tp = weighted.get("Correct Trigger", 0) if "Correct Trigger" in weighted else weighted.get("Positive", 0)
    fp = weighted.get("False Positive", 0)
    fn = weighted.get("Miss", 0) if "Miss" in weighted else weighted.get("Missed Opportunity", 0)
    fn += weighted.get("Negative", 0)

    # Handle toolcall: Missed Opportunity and Negative are both FN
    fn_extra = weighted.get("Negative", 0)
    fn = max(fn, fn_extra)

    precision = tp / (tp + fp + EPS) if (tp + fp) > 0 else 1.0
    recall = tp / (tp + fn + EPS) if (tp + fn) > 0 else 1.0
    f1 = 2 * precision * recall / (precision + recall + EPS)

    return {"precision": precision, "recall": recall, "f1": f1, "tp": tp, "fp": fp, "fn": fn}


def analyze_trend(history: list[dict], dim_name: str) -> dict:
    """Analyze score trend over time. Returns direction and recommendation."""
    if len(history) < 3:
        return {"trend": "insufficient_data", "recommendation": "collect more data"}

    recent = history[-3:]
    f1s = [h.get(dim_name, {}).get("weighted_f1", 0) for h in recent]

    if all(f1s[i] <= f1s[i + 1] for i in range(len(f1s) - 1)):
        return {"trend": "improving", "recommendation": "maintain current thresholds"}
    elif all(f1s[i] >= f1s[i + 1] for i in range(len(f1s) - 1)):
        return {"trend": "declining", "recommendation": "consider adjusting thresholds"}
    else:
        return {"trend": "fluctuating", "recommendation": "collect more data before adjusting"}


def compute_confidence(observations: int, sessions: int) -> float:
    """Confidence score: 0.0 (no data) to 1.0 (high confidence)."""
    if sessions == 0:
        return 0.0
    obs_density = observations / sessions
    return min(1.0, obs_density / 0.5)  # 0.5 obs/session = full confidence


def process_dimension(text: str, dim_name: str, dim_label: str,
                      labels: dict[str, float], meta: dict) -> dict:
    """Process one training dimension with weighted scoring."""
    dim = meta.get("dimensions", {}).get(dim_name, {})
    current_session = meta.get("sessions", 0)
    history = dim.get("history", [])

    # Count weighted entries
    result = count_weighted_entries(text, dim_label, labels, current_session, history)

    # Compute weighted metrics
    weighted_f1 = compute_weighted_f1(result["weighted"])

    # Analyze trend
    trend = analyze_trend(history, dim_name)

    # Confidence
    total_obs = sum(result["raw"].values())
    confidence = compute_confidence(total_obs, current_session)

    return {
        "raw_counts": result["raw"],
        "weighted_scores": result["weighted"],
        "total_weighted": result["total_weighted"],
        "weighted_precision": weighted_f1["precision"],
        "weighted_recall": weighted_f1["recall"],
        "weighted_f1": weighted_f1["f1"],
        "confidence": confidence,
        "trend": trend["trend"],
        "recommendation": trend["recommendation"],
    }


def generate_recommendations(results: dict) -> list[str]:
    """Generate human-readable tuning recommendations."""
    recs = []
    for dim_name, result in results.items():
        label = {"skill": "SkillOpt", "multiagent": "MultiAgentOpt", "toolcall": "ToolCallOpt"}[dim_name]
        f1 = result["weighted_f1"]
        conf = result["confidence"]
        trend = result["trend"]

        if conf < 0.3:
            recs.append(f"[{label}] Low confidence ({conf:.2f}) — need more observations")
        elif f1 < 0.7:
            recs.append(f"[{label}] F1={f1:.3f} ({trend}) — consider threshold adjustment")
        elif trend == "declining":
            recs.append(f"[{label}] F1={f1:.3f} but declining — monitor closely")
        else:
            recs.append(f"[{label}] F1={f1:.3f} ({trend}) — no action needed")
    return recs


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Weighted Scoring Engine for TrainingLoop")
    parser.add_argument("--feedback", type=Path, help="Path to feedback.md")
    parser.add_argument("--meta", type=Path, help="Path to meta.json")
    parser.add_argument("--recommend", action="store_true", help="Print tuning recommendations")
    args = parser.parse_args()

    # Auto-detect paths
    script_dir = Path(__file__).resolve().parent
    harness_root = Path(os.environ.get("HARNESS_ROOT", str(script_dir.parent))).resolve()

    loop_dir = harness_root / "config" / "training-loop" if (harness_root / "config").exists() else harness_root / "training-loop"
    meta_path = args.meta or loop_dir / "meta.json"
    feedback_path = args.feedback or loop_dir / "feedback.md"

    meta = load_json(meta_path)
    feedback_text = feedback_path.read_text(encoding="utf-8") if feedback_path.exists() else ""

    DIMS = {
        "skill": ("SkillOpt", WEIGHTS["skill"]),
        "multiagent": ("MultiAgentOpt", WEIGHTS["multiagent"]),
        "toolcall": ("ToolCallOpt", WEIGHTS["toolcall"]),
    }

    results = {}
    for dim_name, (dim_label, labels) in DIMS.items():
        result = process_dimension(feedback_text, dim_name, dim_label, labels, meta)
        results[dim_name] = result

        print(f"\n[{dim_label}] Weighted Scoring:")
        print(f"  Raw counts: {result['raw_counts']}")
        print(f"  Weighted: {result['weighted_scores']:.3f}" if isinstance(result['weighted_scores'], float)
              else f"  Weighted: {result['weighted_scores']}")
        print(f"  Weighted F1: {result['weighted_f1']:.3f}")
        print(f"  Confidence: {result['confidence']:.2f}")
        print(f"  Trend: {result['trend']}")

    if args.recommend:
        print("\n--- Recommendations ---")
        for rec in generate_recommendations(results):
            print(f"  {rec}")

    # Write results to meta.json for persistence
    if meta:
        for dim_name in ["skill", "multiagent", "toolcall"]:
            if dim_name in results:
                meta.setdefault("dimensions", {}).setdefault(dim_name, {})
                meta["dimensions"][dim_name]["weighted"] = results[dim_name]
        meta["last_weighted_scoring"] = datetime.now(timezone.utc).isoformat()
        save_json(meta_path, meta)


if __name__ == "__main__":
    import os
    main()