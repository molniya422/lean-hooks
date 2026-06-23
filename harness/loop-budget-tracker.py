#!/usr/bin/env python
"""Loop Budget Tracker — token/spend budget with daily caps and kill switch.

Ops:
  check [--pattern P] [--json]    Check current usage vs cap
  record <pattern> <tokens> <run_id>  Add a usage record
  daily-reset                     Rotate daily counters
  set-cap <key> <value>           Update a cap value

Config: config/loop-engineering/budget.json
"""
import argparse
import json
import os
import sys
from datetime import datetime, timezone

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass


def _detect_budget_path():
    loop_budget = os.environ.get("LOOP_BUDGET", "")
    if loop_budget and os.path.isfile(loop_budget):
        return loop_budget
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
    return os.path.join(config_dir, "loop-engineering", "budget.json")


def _load_budget(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def _save_budget(path, budget):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(budget, f, indent=2, ensure_ascii=False)


def _today():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


def cmd_check(budget_path, pattern=None, json_output=False):
    budget = _load_budget(budget_path)
    if not budget:
        result = {"error": "No budget file found", "daily_percent": 0}
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return

    today = _today()
    daily_cap = budget.get("daily_token_cap", 0)
    daily_usage = budget.get("daily_usage", {}).get(today, {})
    tokens_used = daily_usage.get("tokens_used", 0)
    runs = daily_usage.get("runs", 0)
    pct = round(tokens_used / daily_cap * 100, 1) if daily_cap > 0 else 0

    result = {
        "daily_token_cap": daily_cap,
        "daily_tokens_used": tokens_used,
        "daily_percent": pct,
        "daily_runs": runs,
        "daily_run_cap": budget.get("daily_run_cap", 0),
        "status": "ok",
    }

    warn_at = budget.get("alerts", {}).get("warn_at_percent", 80)
    kill_at = budget.get("alerts", {}).get("kill_at_percent", 100)

    if pct >= kill_at:
        result["status"] = "kill"
    elif pct >= warn_at:
        result["status"] = "warning"

    if pattern:
        cost = budget.get("cost_per_pattern", {}).get(pattern, {})
        pattern_used = daily_usage.get("by_pattern", {}).get(pattern, 0)
        pattern_cap = budget.get("daily_token_cap", 0)  # shares daily cap
        result["pattern"] = pattern
        result["pattern_runs_today"] = pattern_used
        result["pattern_cost_per_run"] = cost.get("tokens_per_run", 0)

    kill_switches = budget.get("kill_switch_patterns", [])
    if kill_switches:
        result["kill_switch_patterns"] = kill_switches

    print(json.dumps(result, indent=2, ensure_ascii=False))


def cmd_record(budget_path, pattern, tokens, run_id):
    budget = _load_budget(budget_path)
    if not budget:
        print(json.dumps({"error": "No budget file found"}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)

    today = _today()
    if "daily_usage" not in budget:
        budget["daily_usage"] = {}
    if today not in budget["daily_usage"]:
        budget["daily_usage"][today] = {"tokens_used": 0, "runs": 0, "by_pattern": {}}

    du = budget["daily_usage"][today]
    du["tokens_used"] = du.get("tokens_used", 0) + tokens
    du["runs"] = du.get("runs", 0) + 1
    bp = du.get("by_pattern", {})
    bp[pattern] = bp.get(pattern, 0) + 1
    du["by_pattern"] = bp

    # Auto-prune: keep only last 30 days of daily_usage
    all_days = sorted(budget["daily_usage"].keys())
    if len(all_days) > 30:
        for old_day in all_days[:-30]:
            del budget["daily_usage"][old_day]

    _save_budget(budget_path, budget)
    print(json.dumps({"ok": True, "pattern": pattern, "tokens_recorded": tokens, "run_id": run_id}, ensure_ascii=False))


def cmd_daily_reset(budget_path):
    budget = _load_budget(budget_path)
    if not budget:
        print(json.dumps({"error": "No budget file found"}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)

    # Keep current day, prune older
    today = _today()
    if "daily_usage" in budget:
        budget["daily_usage"] = {k: v for k, v in budget["daily_usage"].items() if k == today}

    _save_budget(budget_path, budget)
    print(json.dumps({"ok": True, "message": "Daily usage counters reset"}, ensure_ascii=False))


def cmd_set_cap(budget_path, key, value):
    budget = _load_budget(budget_path)
    if not budget:
        print(json.dumps({"error": "No budget file found"}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)

    # Try numeric
    try:
        value = int(value)
    except ValueError:
        try:
            value = float(value)
        except ValueError:
            pass  # keep as string

    budget[key] = value
    _save_budget(budget_path, budget)
    print(json.dumps({"ok": True, "key": key, "value": value}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description="Loop Budget Tracker")
    parser.add_argument("command", choices=["check", "record", "daily-reset", "set-cap"])
    parser.add_argument("pattern", nargs="?", help="Pattern name")
    parser.add_argument("tokens", nargs="?", help="Token count for record")
    parser.add_argument("run_id", nargs="?", help="Run ID for record")
    parser.add_argument("--json", action="store_true", help="Machine-readable output")
    parser.add_argument("--budget-file", help="Override budget.json path")
    args = parser.parse_args()

    budget_path = args.budget_file or _detect_budget_path()

    if args.command == "check":
        cmd_check(budget_path, pattern=args.pattern, json_output=args.json)
    elif args.command == "record":
        if not args.pattern or not args.tokens:
            print("Usage: loop-budget-tracker.py record <pattern> <tokens> <run_id>", file=sys.stderr)
            sys.exit(1)
        try:
            tokens = int(args.tokens)
        except ValueError:
            print("Tokens must be an integer", file=sys.stderr)
            sys.exit(1)
        cmd_record(budget_path, args.pattern, tokens, args.run_id or "")
    elif args.command == "daily-reset":
        cmd_daily_reset(budget_path)
    elif args.command == "set-cap":
        if not args.pattern or not args.tokens:
            print("Usage: loop-budget-tracker.py set-cap <key> <value>", file=sys.stderr)
            sys.exit(1)
        cmd_set_cap(budget_path, args.pattern, args.tokens)


if __name__ == "__main__":
    main()
