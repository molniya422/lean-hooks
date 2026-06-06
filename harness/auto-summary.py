#!/usr/bin/env python3
"""Auto session-log writer for claude-mem-lite.

Reads a JSON record from stdin (or --summary/-s/-p/-f flags) and writes a
lightweight session log row to the claude-mem SQLite database. The
mem-search-lite MCP can then search these logs.

Auto-detects DB path from CLAUDE_MEM_DATA_DIR env var, or falls back to
$HARNESS_ROOT/data/claude-mem.db.

Usage:
  echo '{"project":"foo","summary":"fixed login bug","files":"auth.ts,login.tsx","has_substance":true}' | python auto-summary.py
  python auto-summary.py -p foo -s "fixed login bug" -f "auth.ts,login.tsx"
  python auto-summary.py --has-substance false   # skip signal: the AI decided no substance
"""

import json
import os
import sqlite3
import sys
from datetime import datetime, timezone


def find_db():
    """Locate claude-mem.db using CLAUDE_MEM_DATA_DIR or HARNESS_ROOT env vars."""
    data_dir = os.environ.get("CLAUDE_MEM_DATA_DIR")
    if data_dir:
        return os.path.join(data_dir, "claude-mem.db")

    # Fallback: HARNESS_ROOT/data/claude-mem.db
    harness_root = os.environ.get("HARNESS_ROOT")
    if harness_root:
        return os.path.join(harness_root, "data", "claude-mem.db")

    # Last resort: relative to this script's location
    candidate = os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "..", "data"
    )
    return os.path.join(os.path.abspath(candidate), "claude-mem.db")


def ensure_schema(conn):
    conn.execute(
        """CREATE TABLE IF NOT EXISTS session_logs (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            project     TEXT    NOT NULL DEFAULT 'unknown',
            created_at  TEXT    NOT NULL,
            created_epoch INTEGER NOT NULL,
            summary     TEXT    NOT NULL DEFAULT '',
            files_touched TEXT   NOT NULL DEFAULT '',
            has_substance INTEGER NOT NULL DEFAULT 1
        )"""
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_session_logs_project "
        "ON session_logs(project)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_session_logs_created "
        "ON session_logs(created_epoch DESC)"
    )


def parse_input():
    """Accept: stdin JSON, or CLI flags -p/-s/-f/--has-substance."""
    if not sys.stdin.isatty():
        raw = sys.stdin.read().strip()
        if raw:
            try:
                return json.loads(raw)
            except json.JSONDecodeError:
                print("auto-summary: invalid JSON from stdin", file=sys.stderr)
                sys.exit(1)

    # Fallback to CLI flags
    import argparse
    ap = argparse.ArgumentParser(description="Write a session log row")
    ap.add_argument("-p", "--project", default=os.path.basename(os.getcwd()))
    ap.add_argument("-s", "--summary", default="")
    ap.add_argument("-f", "--files", default="")
    ap.add_argument("--has-substance", dest="has_substance", default=None,
                    choices=["true", "false"])
    args = ap.parse_args()

    hs = None
    if args.has_substance == "true":
        hs = True
    elif args.has_substance == "false":
        hs = False

    return {
        "project": args.project,
        "summary": args.summary,
        "files": args.files,
        "has_substance": hs,
    }


def main():
    record = parse_input()

    has_substance = record.get("has_substance")
    if has_substance is False:
        # AI explicitly signaled "nothing worth logging"
        print("auto-summary: skipped (no substance)")
        return

    # Allow explicit has_substance=True to override, but default to checking
    summary = (record.get("summary") or "").strip()
    files = (record.get("files") or "").strip()
    if has_substance is not True and not summary and not files:
        print("auto-summary: skipped (empty)")
        return

    db_path = find_db()
    now = datetime.now(timezone.utc)
    now_iso = now.isoformat()
    now_epoch = int(now.timestamp())

    conn = sqlite3.connect(db_path)
    try:
        ensure_schema(conn)
        conn.execute(
            "INSERT INTO session_logs (project, created_at, created_epoch, summary, files_touched, has_substance) "
            "VALUES (?, ?, ?, ?, ?, ?)",
            (record.get("project", "unknown"), now_iso, now_epoch, summary, files, 1),
        )
        conn.commit()
        print(f"auto-summary: logged [{record.get('project')}] {summary[:60]}{'...' if len(summary) > 60 else ''}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
