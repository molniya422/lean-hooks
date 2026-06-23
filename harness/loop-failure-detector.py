#!/usr/bin/env python
"""Loop Failure Detector — runtime detection of loop failure modes.

Ops:
  check [--pattern P]    Run all detection rules on specified or all patterns
  check --session        Lightweight check based on current session data
  report                 Output full JSON report of all detected failures

Failure modes catalog (from Loop Engineering failure-modes.md):
  infinite_fix_loop, state_rot, verifier_theater, notification_fatigue,
  token_burn, over_reach, escalation_failure, dead_loop, budget_blowout

Data: reads config/loop-engineering/states/*.json, run-log.jsonl, budget.json
Output: config/loop-engineering/failure-report.json
"""
import argparse
import json
import os
import sys
from datetime import datetime, timezone, timedelta

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

KNOWN_PATTERNS = [
    "daily-triage", "pr-babysitter", "ci-sweeper",
    "dependency-sweeper", "changelog-drafter", "post-merge-cleanup", "issue-triage",
]

CADENCE_HOURS = {
    "daily-triage": 24, "pr-babysitter": 0.25, "ci-sweeper": 0.25,
    "dependency-sweeper": 12, "changelog-drafter": 24,
    "post-merge-cleanup": 12, "issue-triage": 12,
}


def _detect_paths():
    harness_root = os.environ.get("HARNESS_ROOT", "")
    config_dir = os.environ.get("CONFIG_DIR", "")
    if not config_dir:
        if harness_root:
            candidate = os.path.join(harness_root, "config")
            config_dir = candidate if os.path.isdir(candidate) else harness_root
        else:
            script_dir = os.path.dirname(os.path.abspath(__file__))
            parent = os.path.dirname(script_dir)
            config_dir = parent if os.path.basename(parent) == "config" else script_dir

    loop_eng_dir = os.path.join(config_dir, "loop-engineering")
    return {
        "states_dir": os.path.join(loop_eng_dir, "states"),
        "run_log": os.path.join(loop_eng_dir, "run-log.jsonl"),
        "budget": os.path.join(loop_eng_dir, "budget.json"),
        "report": os.path.join(loop_eng_dir, "failure-report.json"),
    }


def _load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _load_state(states_dir, pattern):
    return _load_json(os.path.join(states_dir, f"{pattern}.json"))


def _parse_run_log(run_log_path):
    entries = []
    if not os.path.isfile(run_log_path):
        return entries
    with open(run_log_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    entries.append(json.loads(line))
                except Exception:
                    pass
    return entries


def _detect_infinite_fix_loop(pattern, state, entries):
    """>=3 consecutive partial outcomes with same pending_items"""
    pattern_entries = [e for e in entries if e.get("pattern") == pattern]
    if len(pattern_entries) < 3:
        return None
    recent = pattern_entries[-3:]
    if all(e.get("outcome") == "partial" for e in recent):
        pending = state.get("pending_items", []) if state else []
        if pending and len(pending) > 0:
            return {
                "mode": "infinite_fix_loop",
                "pattern": pattern,
                "severity": "critical",
                "detail": f"3 consecutive partial outcomes with {len(pending)} pending items",
                "remediation": "Human review required. Check if root cause is misdiagnosed."
            }
    return None


def _detect_state_rot(pattern, state):
    """State rot: pending_items unchanged for extended period, or dead loop"""
    if not state:
        return None

    now = datetime.now(timezone.utc)

    # Consecutive failures >= 3
    if state.get("consecutive_failures", 0) >= 3:
        return {
            "mode": "state_rot",
            "pattern": pattern,
            "severity": "high",
            "detail": f"{state['consecutive_failures']} consecutive failures",
            "remediation": "Check for blockers. Consider resetting the loop."
        }

    # Last run older than 3x cadence
    last_run = state.get("last_run")
    if last_run:
        try:
            lr = datetime.fromisoformat(last_run)
            if lr.tzinfo is None:
                lr = lr.replace(tzinfo=timezone.utc)
            age_hours = (now - lr).total_seconds() / 3600
            cadence = CADENCE_HOURS.get(pattern, 24)
            if age_hours > cadence * 3:
                return {
                    "mode": "state_rot",
                    "pattern": pattern,
                    "severity": "high",
                    "detail": f"Last run {age_hours:.0f}h ago (cadence: {cadence}h)",
                    "remediation": "Re-trigger the loop or check for blockers."
                }
        except Exception:
            pass

    return None


def _detect_verifier_theater(pattern, entries):
    """checker_result always 'pass' but 0 escalations"""
    pattern_entries = [e for e in entries if e.get("pattern") == pattern]
    if len(pattern_entries) < 5:
        return None
    recent = pattern_entries[-10:]
    checkers = [e for e in recent if e.get("checker_result")]
    if len(checkers) >= 5 and all(e.get("checker_result") == "pass" for e in checkers):
        escalated = sum(1 for e in recent if e.get("escalations", 0) > 0)
        if escalated == 0:
            return {
                "mode": "verifier_theater",
                "pattern": pattern,
                "severity": "medium",
                "detail": f"Last {len(checkers)} checks all pass with 0 escalations",
                "remediation": "Verifier may be rubber-stamping. Use different model or add rejection criteria."
            }
    return None


def _detect_notification_fatigue(pattern, entries):
    """>=5 escalations in 24h with no human action"""
    now = datetime.now(timezone.utc)
    cutoff = (now - timedelta(hours=24)).isoformat()
    pattern_entries = [e for e in entries if e.get("pattern") == pattern and e.get("started_at", "") >= cutoff]
    total_escalations = sum(e.get("escalations", 0) for e in pattern_entries)
    if total_escalations >= 5:
        return {
            "mode": "notification_fatigue",
            "pattern": pattern,
            "severity": "medium",
            "detail": f"{total_escalations} escalations in 24h",
            "remediation": "Tighten triage rules. Increase bar for 'high priority'."
        }
    return None


def _detect_token_burn(pattern, entries, budget):
    """Pattern exceeds 2x its cost_per_run estimate in a single run"""
    cost = budget.get("cost_per_pattern", {}).get(pattern, {}) if budget else {}
    expected = cost.get("tokens_per_run", 0)
    if expected <= 0:
        return None
    pattern_entries = [e for e in entries if e.get("pattern") == pattern]
    for e in pattern_entries[-5:]:
        if e.get("token_estimate", 0) > expected * 2:
            return {
                "mode": "token_burn",
                "pattern": pattern,
                "severity": "high",
                "detail": f"Run used {e['token_estimate']} tokens vs expected {expected}",
                "remediation": "Check for infinite loops or overly broad context."
            }
    return None


def _detect_escalation_failure(pattern, state):
    """escalated_items unresolved > 7 days"""
    if not state:
        return None
    escalated = state.get("escalated_items", [])
    if not escalated:
        return None

    # Check if last_run > 7 days ago and still has escalated items
    last_run = state.get("last_run")
    if last_run:
        try:
            lr = datetime.fromisoformat(last_run)
            if lr.tzinfo is None:
                lr = lr.replace(tzinfo=timezone.utc)
            age_days = (datetime.now(timezone.utc) - lr).days
            if age_days > 7 and len(escalated) > 0:
                return {
                    "mode": "escalation_failure",
                    "pattern": pattern,
                    "severity": "medium",
                    "detail": f"{len(escalated)} escalated items unresolved for {age_days} days",
                    "remediation": "Send notification to human. Check why items are stuck."
                }
        except Exception:
            pass

    return None


def _detect_dead_loop(pattern, entries):
    """No run in 3x cadence"""
    pattern_entries = [e for e in entries if e.get("pattern") == pattern]
    if not pattern_entries:
        return None

    latest = pattern_entries[-1]
    try:
        last_time = datetime.fromisoformat(latest.get("started_at", ""))
        if last_time.tzinfo is None:
            last_time = last_time.replace(tzinfo=timezone.utc)
        age_hours = (datetime.now(timezone.utc) - last_time).total_seconds() / 3600
        cadence = CADENCE_HOURS.get(pattern, 24)
        if age_hours > cadence * 3:
            return {
                "mode": "dead_loop",
                "pattern": pattern,
                "severity": "medium",
                "detail": f"Last run {age_hours:.0f}h ago (cadence: {cadence}h)",
                "remediation": "Check if scheduler is running. Re-trigger if needed."
            }
    except Exception:
        pass

    return None


def _detect_budget_blowout(budget):
    """Daily usage > 120% despite kill switch"""
    if not budget:
        return None
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    daily_cap = budget.get("daily_token_cap", 0)
    if daily_cap <= 0:
        return None
    usage = budget.get("daily_usage", {}).get(today, {})
    tokens_used = usage.get("tokens_used", 0)
    pct = tokens_used / daily_cap * 100
    if pct > 120:
        return {
            "mode": "budget_blowout",
            "pattern": "_global",
            "severity": "critical",
            "detail": f"Daily usage at {pct:.0f}% of cap ({tokens_used}/{daily_cap})",
            "remediation": "All loops should be paused. Kill switch may not be working."
        }
    return None


def detect_all(patterns=None, session_only=False):
    paths = _detect_paths()
    states_dir = paths["states_dir"]
    run_log_path = paths["run_log"]
    budget_path = paths["budget"]

    budget = _load_json(budget_path)
    entries = _parse_run_log(run_log_path)

    check_patterns = patterns or KNOWN_PATTERNS
    if isinstance(check_patterns, str):
        check_patterns = [check_patterns]

    failures = []
    healthy = []

    for pattern in check_patterns:
        state = _load_state(states_dir, pattern)
        pattern_failures = []

        # Run all detectors
        detectors = [
            lambda p=pattern, s=state, e=entries: _detect_infinite_fix_loop(p, s, e),
            lambda p=pattern, s=state: _detect_state_rot(p, s),
            lambda p=pattern, e=entries: _detect_verifier_theater(p, e),
            lambda p=pattern, e=entries: _detect_notification_fatigue(p, e),
            lambda p=pattern, e=entries, b=budget: _detect_token_burn(p, e, b),
            lambda p=pattern, s=state: _detect_escalation_failure(p, s),
            lambda p=pattern, e=entries: _detect_dead_loop(p, e),
        ]

        for detector in detectors:
            try:
                result = detector()
                if result:
                    pattern_failures.append(result)
            except Exception:
                pass

        if pattern_failures:
            failures.extend(pattern_failures)
        else:
            healthy.append(pattern)

    # Global checks
    global_failure = _detect_budget_blowout(budget)
    if global_failure:
        failures.append(global_failure)

    summary = {"critical": 0, "high": 0, "medium": 0}
    for f in failures:
        sev = f.get("severity", "medium")
        if sev in summary:
            summary[sev] += 1

    result = {
        "failures": failures,
        "healthy_patterns": healthy,
        "last_checked": datetime.now(timezone.utc).isoformat(),
        "summary": summary,
    }

    # Write to failure-report.json
    report_path = paths["report"]
    try:
        os.makedirs(os.path.dirname(report_path), exist_ok=True)
        with open(report_path, "w", encoding="utf-8") as f:
            json.dump(result, f, indent=2, ensure_ascii=False)
    except Exception:
        pass

    return result


def main():
    parser = argparse.ArgumentParser(description="Loop Failure Detector")
    parser.add_argument("command", nargs="?", default="check", choices=["check", "report"])
    parser.add_argument("--pattern", help="Check specific pattern")
    parser.add_argument("--session", action="store_true", help="Lightweight session check")
    parser.add_argument("--json", action="store_true", help="Machine-readable output")
    args = parser.parse_args()

    patterns = [args.pattern] if args.pattern else None
    result = detect_all(patterns=patterns, session_only=args.session)

    if args.command == "report" or args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        if result["failures"]:
            print("[LoopFailure] Failures detected:")
            for f in result["failures"]:
                print(f"  [{f['severity'].upper()}] {f['mode']}: {f['pattern']} — {f['detail']}")
            print(f"\n  Healthy: {', '.join(result['healthy_patterns']) or 'none'}")
        else:
            print("[LoopFailure] All patterns healthy ✎")
            print(f"  Checked: {', '.join(KNOWN_PATTERNS)}")


if __name__ == "__main__":
    main()
