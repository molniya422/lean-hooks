#!/usr/bin/env python
"""Loop State Manager — per-pattern state CRUD with rot detection.

Ops:
  init <pattern>           Create state file with defaults
  read <pattern>           Output state JSON to stdout
  write <pattern> <key> <value>  Atomic update (read-modify-write)
  prune <pattern>          Archive resolved items, reset stale counters
  rot-check <pattern> [--stale-days N]  Detect state rot

State files: config/loop-engineering/states/<pattern>.json
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

# --- Path detection ---
def _detect_paths():
    harness_root = os.environ.get("HARNESS_ROOT", "")
    config_dir = os.environ.get("CONFIG_DIR", "")
    if not config_dir:
        if harness_root:
            candidate = os.path.join(harness_root, "config")
            if os.path.isdir(candidate):
                config_dir = candidate
            else:
                config_dir = harness_root
        else:
            script_dir = os.path.dirname(os.path.abspath(__file__))
            parent = os.path.dirname(script_dir)
            if os.path.basename(parent) == "config":
                config_dir = parent
                harness_root = os.path.dirname(parent)
            else:
                config_dir = script_dir
                harness_root = parent

    loop_eng_dir = os.environ.get("LOOP_ENG_DIR", os.path.join(config_dir, "loop-engineering"))
    states_dir = os.environ.get("LOOP_STATES_DIR", os.path.join(loop_eng_dir, "states"))
    return harness_root, config_dir, loop_eng_dir, states_dir


def _now_iso():
    return datetime.now(timezone.utc).isoformat()


def _state_path(states_dir, pattern):
    return os.path.join(states_dir, f"{pattern}.json")


def _load_state(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _save_state(path, state):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)


def _default_state(pattern):
    return {
        "pattern": pattern,
        "status": "active",
        "readiness_level": "L0",
        "last_run": None,
        "last_run_id": None,
        "pending_items": [],
        "resolved_items": [],
        "escalated_items": [],
        "consecutive_failures": 0,
        "total_runs": 0,
        "total_successes": 0,
        "total_escalations": 0,
        "created_at": _now_iso(),
        "updated_at": _now_iso(),
    }


# Cadence in hours (for rot detection)
CADENCE_HOURS = {
    "daily-triage": 24,
    "pr-babysitter": 0.25,
    "ci-sweeper": 0.25,
    "dependency-sweeper": 12,
    "changelog-drafter": 24,
    "post-merge-cleanup": 12,
    "issue-triage": 12,
}


def cmd_init(states_dir, pattern):
    path = _state_path(states_dir, pattern)
    if os.path.isfile(path):
        print(f"State already exists: {path}", file=sys.stderr)
        return
    state = _default_state(pattern)
    _save_state(path, state)
    print(json.dumps({"ok": True, "path": path, "pattern": pattern}, ensure_ascii=False))


def cmd_read(states_dir, pattern):
    path = _state_path(states_dir, pattern)
    state = _load_state(path)
    if state is None:
        print(json.dumps({"error": f"No state for pattern '{pattern}'"}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
    print(json.dumps(state, indent=2, ensure_ascii=False))


def cmd_write(states_dir, pattern, key, value):
    path = _state_path(states_dir, pattern)
    state = _load_state(path)
    if state is None:
        print(json.dumps({"error": f"No state for pattern '{pattern}'"}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
    # Try to parse value as JSON; fall back to string
    try:
        parsed = json.loads(value)
    except (json.JSONDecodeError, TypeError):
        parsed = value
    state[key] = parsed
    state["updated_at"] = _now_iso()
    _save_state(path, state)
    print(json.dumps({"ok": True, "pattern": pattern, "key": key}, ensure_ascii=False))


def cmd_prune(states_dir, pattern):
    path = _state_path(states_dir, pattern)
    state = _load_state(path)
    if state is None:
        print(json.dumps({"error": f"No state for pattern '{pattern}'"}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)
    pruned_count = len(state.get("resolved_items", []))
    state["resolved_items"] = []
    state["updated_at"] = _now_iso()
    _save_state(path, state)
    print(json.dumps({"ok": True, "pattern": pattern, "pruned": pruned_count}, ensure_ascii=False))


def cmd_rot_check(states_dir, pattern, stale_days=7):
    path = _state_path(states_dir, pattern)
    state = _load_state(path)
    if state is None:
        print(json.dumps({"pattern": pattern, "rot_detected": True, "rot_type": "no_state", "detail": "No state file exists", "remediation": "Run: loop-state-manager.py init " + pattern}, ensure_ascii=False))
        return

    now = datetime.now(timezone.utc)
    rot_detected = False
    rot_type = None
    detail = ""

    # 1. Consecutive failures >= 3
    if state.get("consecutive_failures", 0) >= 3:
        rot_detected = True
        rot_type = "stuck_loop"
        detail = f"{state['consecutive_failures']} consecutive failures"
    # 2. Last run older than 3x cadence
    elif state.get("last_run"):
        cadence_h = CADENCE_HOURS.get(pattern, 24)
        try:
            last_run = datetime.fromisoformat(state["last_run"])
            if last_run.tzinfo is None:
                last_run = last_run.replace(tzinfo=timezone.utc)
            age_hours = (now - last_run).total_seconds() / 3600
            if age_hours > cadence_h * 3:
                rot_detected = True
                rot_type = "dead_loop"
                detail = f"Last run {age_hours:.0f}h ago (cadence: {cadence_h}h, threshold: {cadence_h*3}h)"
        except Exception:
            pass
    # 3. Pending items unchanged for stale_days
    elif state.get("pending_items") and not state.get("resolved_items"):
        if state.get("total_runs", 0) >= stale_days and state.get("total_successes", 0) == 0:
            rot_detected = True
            rot_type = "stale_state"
            detail = f"pending_items unchanged for {stale_days} days (cadence: {CADENCE_HOURS.get(pattern, 24)}h)"

    result = {
        "pattern": pattern,
        "rot_detected": rot_detected,
    }
    if rot_detected:
        result.update({"rot_type": rot_type, "detail": detail, "remediation": "Re-trigger the loop or check for blockers"})
    print(json.dumps(result, indent=2, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description="Loop State Manager")
    parser.add_argument("command", choices=["init", "read", "write", "prune", "rot-check"])
    parser.add_argument("pattern", help="Pattern name (e.g. daily-triage)")
    parser.add_argument("key", nargs="?", help="Key for write command")
    parser.add_argument("value", nargs="?", help="Value for write command")
    parser.add_argument("--stale-days", type=int, default=7, help="Days before state considered stale")
    parser.add_argument("--states-dir", help="Override states directory")
    args = parser.parse_args()

    _, _, _, default_states_dir = _detect_paths()
    states_dir = args.states_dir or default_states_dir

    if args.command == "init":
        cmd_init(states_dir, args.pattern)
    elif args.command == "read":
        cmd_read(states_dir, args.pattern)
    elif args.command == "write":
        if not args.key or args.value is None:
            print("Usage: loop-state-manager.py write <pattern> <key> <value>", file=sys.stderr)
            sys.exit(1)
        cmd_write(states_dir, args.pattern, args.key, args.value)
    elif args.command == "prune":
        cmd_prune(states_dir, args.pattern)
    elif args.command == "rot-check":
        cmd_rot_check(states_dir, args.pattern, stale_days=args.stale_days)


if __name__ == "__main__":
    main()
