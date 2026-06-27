#!/usr/bin/env python3
"""Schema migration for memory evolution system.

Adds columns for supersedes chains, temporal expiration,
quality scoring, and invalidation to the observations and
session_logs tables.

Idempotent — safe to re-run. Uses schema_versions table for
version tracking (same mechanism as the claude-mem plugin).

Usage:
    python db-migrate.py
    python db-migrate.py --dry-run
"""

import os
import re
import sqlite3
import sys
import time
from pathlib import Path

MIGRATION_VERSION = 34

# --- Path resolution (same pattern as auto-summary.py) ---

def find_db():
    data_dir = os.environ.get("CLAUDE_MEM_DATA_DIR")
    if data_dir:
        return os.path.join(data_dir, "claude-mem.db")

    harness_root = os.environ.get("HARNESS_ROOT")
    if harness_root:
        return os.path.join(harness_root, "data", "claude-mem", "claude-mem.db")

    script_dir = Path(__file__).resolve().parent
    parent = script_dir.parent
    if parent.name == "config":
        root = parent.parent
    else:
        root = parent
    return str(root / "data" / "claude-mem" / "claude-mem.db")


def get_applied_version(conn):
    try:
        cur = conn.execute(
            "SELECT MAX(version) FROM schema_versions"
        )
        row = cur.fetchone()
        return row[0] if row and row[0] is not None else 0
    except sqlite3.OperationalError:
        return 0


def column_exists(conn, table, column):
    if not re.match(r'^[A-Za-z_]\w*$', table):
        return False
    cur = conn.execute(f"PRAGMA table_info({table})")
    return any(row[1] == column for row in cur.fetchall())


def run_migration(dry_run=False):
    db_path = find_db()
    if not os.path.isfile(db_path):
        print(f"db-migrate: DB not found at {db_path}")
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    try:
        current = get_applied_version(conn)
        if current >= MIGRATION_VERSION:
            print(f"db-migrate: v{MIGRATION_VERSION} already applied (current v{current})")
            return

        now_iso = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
        statements = []

        # --- observations table: 4 new columns ---
        obs_columns = [
            ("supersedes_id", "INTEGER", "NULL",
             "ID of the observation this one replaces"),
            ("expires_at_epoch", "INTEGER", "NULL",
             "When this observation auto-expires (unix epoch)"),
            ("quality_score", "REAL", "0.5",
             "Computed quality 0.0-1.0"),
            ("invalidated_at_epoch", "INTEGER", "NULL",
             "When this observation was marked invalid/contradicted"),
        ]
        for col_name, col_type, default, _ in obs_columns:
            if not column_exists(conn, "observations", col_name):
                statements.append(
                    f"ALTER TABLE observations ADD COLUMN {col_name} {col_type} DEFAULT {default}"
                )

        # --- session_logs table: 2 new columns ---
        sl_columns = [
            ("expires_at_epoch", "INTEGER", "NULL",
             "When this session log auto-expires"),
            ("quality_score", "REAL", "0.5",
             "Quality score"),
        ]
        for col_name, col_type, default, _ in sl_columns:
            if not column_exists(conn, "session_logs", col_name):
                statements.append(
                    f"ALTER TABLE session_logs ADD COLUMN {col_name} {col_type} DEFAULT {default}"
                )

        # --- Indexes ---
        index_ddl = [
            ("idx_obs_supersedes", "CREATE INDEX IF NOT EXISTS idx_obs_supersedes ON observations(supersedes_id)"),
            ("idx_obs_quality", "CREATE INDEX IF NOT EXISTS idx_obs_quality ON observations(quality_score DESC)"),
            ("idx_sl_expires", "CREATE INDEX IF NOT EXISTS idx_sl_expires ON session_logs(expires_at_epoch)"),
        ]
        for _, ddl in index_ddl:
            statements.append(ddl)

        # Partial indexes (WHERE clause) — SQLite supports these
        partial_indexes = [
            ("idx_obs_expires",
             "CREATE INDEX IF NOT EXISTS idx_obs_expires ON observations(expires_at_epoch) WHERE expires_at_epoch IS NOT NULL"),
            ("idx_obs_invalidated",
             "CREATE INDEX IF NOT EXISTS idx_obs_invalidated ON observations(invalidated_at_epoch) WHERE invalidated_at_epoch IS NOT NULL"),
        ]
        for _, ddl in partial_indexes:
            statements.append(ddl)

        # --- v34: skill_attention tables ---
        if current < 34:
            statements.extend([
                """CREATE TABLE IF NOT EXISTS skill_attention (
                    id              INTEGER PRIMARY KEY AUTOINCREMENT,
                    skill_name      TEXT    NOT NULL,
                    utterance       TEXT    NOT NULL,
                    embedding       BLOB    NOT NULL,
                    weight          REAL    NOT NULL DEFAULT 1.0,
                    source          TEXT    NOT NULL DEFAULT 'seed',
                    created_epoch   INTEGER NOT NULL,
                    updated_epoch   INTEGER NOT NULL,
                    UNIQUE(skill_name, utterance)
                )""",
                """CREATE TABLE IF NOT EXISTS skill_attention_weights (
                    skill_name      TEXT    PRIMARY KEY,
                    attention_weight REAL  NOT NULL DEFAULT 1.0,
                    trigger_count   INTEGER NOT NULL DEFAULT 0,
                    fp_count        INTEGER NOT NULL DEFAULT 0,
                    fn_count        INTEGER NOT NULL DEFAULT 0,
                    last_updated_epoch INTEGER NOT NULL DEFAULT 0
                )""",
                "CREATE INDEX IF NOT EXISTS idx_skill_attention_skill ON skill_attention(skill_name)",
                "CREATE INDEX IF NOT EXISTS idx_skill_attention_source ON skill_attention(source)",
            ])

        if not statements:
            print(f"db-migrate: no new columns/indexes needed (v{current} → v{MIGRATION_VERSION})")
            return

        if dry_run:
            print(f"db-migrate: DRY-RUN — would execute {len(statements)} statements for v{MIGRATION_VERSION}:")
            for s in statements:
                print(f"  {s}")
            return

        for s in statements:
            conn.execute(s)

        conn.execute(
            "INSERT INTO schema_versions (version, applied_at) VALUES (?, ?)",
            (MIGRATION_VERSION, now_iso),
        )
        conn.commit()
        print(f"db-migrate: applied v{MIGRATION_VERSION} ({len(statements)} statements)")
    finally:
        conn.close()


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Memory evolution schema migration")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    run_migration(args.dry_run)
