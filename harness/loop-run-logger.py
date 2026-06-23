#!/usr/bin/env python
"""Loop Run Logger — append-only audit trail of every loop execution.

Ops:
  append <entry-json>     Add entry to run-log.jsonl
  query [--pattern P] [--last N] [--from DATE] [--outcome STATUS]
  stats [--pattern P]     Aggregate stats
  prune [--older-than Nd] Archive old entries

Data file: config/loop-engineering/run-log.jsonl
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

    loop_eng_dir = os.environ.get("LOOP_ENG_DIR", os.path.join(config_dir, "loop-engineering"))
    run_log = os.environ.get("LOOP_RUN_LOG", os.path.join(loop_eng_dir, "run-log.jsonl"))
    archive_dir = os.environ.get("LOOP_ARCHIVE_DIR", os.path.join(loop_eng_dir, "archive"))
    return run_log, archive_dir


def _parse_entries(path):
    entries = []
    if not os.path.isfile(path):
        return entries
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return entries


def cmd_append(run_log_path, entry_json):
    try:
        entry = json.loads(entry_json)
    except json.JSONDecodeError:
        print(json.dumps({"error": "Invalid JSON entry"}, ensure_ascii=False), file=sys.stderr)
        sys.exit(1)

    # Validate required fields
    for field in ["run_id", "pattern", "started_at", "ended_at", "outcome"]:
        if field not in entry:
            print(json.dumps({"error": f"Missing required field: {field}"}, ensure_ascii=False), file=sys.stderr)
            sys.exit(1)

    os.makedirs(os.path.dirname(run_log_path), exist_ok=True)
    with open(run_log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    print(json.dumps({"ok": True, "run_id": entry["run_id"], "pattern": entry["pattern"]}, ensure_ascii=False))


def cmd_query(run_log_path, pattern=None, last=None, from_date=None, outcome=None):
    entries = _parse_entries(run_log_path)
    if pattern:
        entries = [e for e in entries if e.get("pattern") == pattern]
    if from_date:
        try:
            from_dt = datetime.fromisoformat(from_date)
            if from_dt.tzinfo is None:
                from_dt = from_dt.replace(tzinfo=timezone.utc)
            entries = [e for e in entries if e.get("started_at", "") >= from_date]
        except ValueError:
            pass
    if outcome:
        entries = [e for e in entries if e.get("outcome") == outcome]
    if last:
        entries = entries[-last:]

    print(json.dumps(entries, indent=2, ensure_ascii=False))


def cmd_stats(run_log_path, pattern=None):
    entries = _parse_entries(run_log_path)
    if pattern:
        entries = [e for e in entries if e.get("pattern") == pattern]

    total = len(entries)
    by_outcome = {}
    total_tokens = 0
    total_duration = 0
    by_pattern = {}

    for e in entries:
        oc = e.get("outcome", "unknown")
        by_outcome[oc] = by_outcome.get(oc, 0) + 1
        total_tokens += e.get("token_estimate", 0)
        total_duration += e.get("duration_seconds", 0)
        p = e.get("pattern", "unknown")
        if p not in by_pattern:
            by_pattern[p] = {"runs": 0, "tokens": 0, "duration": 0}
        by_pattern[p]["runs"] += 1
        by_pattern[p]["tokens"] += e.get("token_estimate", 0)
        by_pattern[p]["duration"] += e.get("duration_seconds", 0)

    result = {
        "total_runs": total,
        "by_outcome": by_outcome,
        "total_tokens_estimated": total_tokens,
        "total_duration_seconds": total_duration,
        "by_pattern": by_pattern,
    }
    if pattern:
        result["pattern_filter"] = pattern
    print(json.dumps(result, indent=2, ensure_ascii=False))


def cmd_prune(run_log_path, archive_dir, older_than_days=90):
    if not os.path.isfile(run_log_path):
        print(json.dumps({"ok": True, "pruned": 0}, ensure_ascii=False))
        return

    cutoff = (datetime.now(timezone.utc) - timedelta(days=older_than_days)).isoformat()
    entries = _parse_entries(run_log_path)
    keep = []
    archive = []
    for e in entries:
        if e.get("started_at", "") < cutoff:
            archive.append(e)
        else:
            keep.append(e)

    # Rewrite run-log with kept entries
    with open(run_log_path, "w", encoding="utf-8") as f:
        for e in keep:
            f.write(json.dumps(e, ensure_ascii=False) + "\n")

    # Append archived entries to archive file
    if archive:
        os.makedirs(archive_dir, exist_ok=True)
        archive_path = os.path.join(archive_dir, f"run-log-{datetime.now(timezone.utc).strftime('%Y%m%d')}.jsonl")
        with open(archive_path, "a", encoding="utf-8") as f:
            for e in archive:
                f.write(json.dumps(e, ensure_ascii=False) + "\n")

    print(json.dumps({"ok": True, "pruned": len(archive), "kept": len(keep)}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description="Loop Run Logger")
    parser.add_argument("command", choices=["append", "query", "stats", "prune"])
    parser.add_argument("entry_json", nargs="?", help="JSON entry for append")
    parser.add_argument("--pattern", help="Filter by pattern name")
    parser.add_argument("--last", type=int, help="Last N entries")
    parser.add_argument("--from", dest="from_date", help="From date (ISO format)")
    parser.add_argument("--outcome", help="Filter by outcome")
    parser.add_argument("--older-than", type=int, default=90, help="Prune entries older than N days")
    parser.add_argument("--run-log", help="Override run-log path")
    args = parser.parse_args()

    default_run_log, default_archive_dir = _detect_paths()
    run_log_path = args.run_log or default_run_log

    if args.command == "append":
        if not args.entry_json:
            print("Usage: loop-run-logger.py append '<entry-json>'", file=sys.stderr)
            sys.exit(1)
        cmd_append(run_log_path, args.entry_json)
    elif args.command == "query":
        cmd_query(run_log_path, pattern=args.pattern, last=args.last, from_date=args.from_date, outcome=args.outcome)
    elif args.command == "stats":
        cmd_stats(run_log_path, pattern=args.pattern)
    elif args.command == "prune":
        cmd_prune(run_log_path, default_archive_dir, older_than_days=args.older_than)


if __name__ == "__main__":
    main()
