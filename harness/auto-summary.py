#!/usr/bin/env python3
"""Auto session-log writer for claude-mem-lite.

Reads a JSON record from stdin (or --summary/-s/-p/-f flags) and writes a
lightweight session log row to the claude-mem SQLite database. The
mem-search-lite MCP can then search these logs.

Auto-detects DB path from CLAUDE_MEM_DATA_DIR, or falls back to:
  - <HARNESS_ROOT>/data/claude-mem/claude-mem.db (lean-hooks)
  - <HARNESS_ROOT>/data/claude-mem/claude-mem.db (claude-ecosystem, HARNESS_ROOT is project root)

Usage:
  echo '{"project":"foo","summary":"fixed login bug","files":"auth.ts,login.tsx","has_substance":true}' | python auto-summary.py
  python auto-summary.py -p foo -s "fixed login bug" -f "auth.ts,login.tsx"
  python auto-summary.py --has-substance false   # skip signal
"""

import json
import os
import sqlite3
import sys
from datetime import datetime, timezone

# Ensure UTF-8 on Windows MINGW64 (prevents surrogate errors from stdin pipe)
for stream in (sys.stdin, sys.stdout, sys.stderr):
    if hasattr(stream, "reconfigure"):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (OSError, ValueError):
            pass


def sanitize_unicode(text):
    """Replace invalid UTF-16 surrogates with replacement character."""
    if not isinstance(text, str):
        return text
    # errors='replace' on encode+decode strips surrogates safely
    return text.encode("utf-8", errors="replace").decode("utf-8", errors="replace")


def find_db():
    data_dir = os.environ.get("CLAUDE_MEM_DATA_DIR")
    if data_dir:
        return os.path.join(data_dir, "claude-mem.db")

    harness_root = os.environ.get("HARNESS_ROOT")
    if harness_root:
        candidate = os.path.join(harness_root, "data", "claude-mem")
        data_dir = os.path.abspath(candidate)
        return os.path.join(data_dir, "claude-mem.db")

    # Fallback: auto-detect layout from script location
    script_dir = os.path.dirname(os.path.abspath(__file__))
    # If harness is under config/harness/ (claude-ecosystem) or harness/ (lean-hooks)
    parent = os.path.dirname(script_dir)
    if os.path.basename(parent) == "config":
        # claude-ecosystem: script_dir = config/harness, project root = grandparent
        root = os.path.dirname(parent)
    else:
        # lean-hooks: script_dir = harness, project root = parent
        root = parent
    data_dir = os.path.abspath(os.path.join(root, "data", "claude-mem"))
    return os.path.join(data_dir, "claude-mem.db")


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
                print(f"auto-summary: invalid JSON from stdin", file=sys.stderr)
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

    # Sanitize any invalid surrogates from stdin/CLI input before touching DB
    for key in ("project", "summary", "files"):
        record[key] = sanitize_unicode(record.get(key) or "")

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
