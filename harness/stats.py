#!/usr/bin/env python3
"""
lean-hooks stats CLI — query and visualize session/hook/feedback data.

Provides insight into:
  - Session statistics (count, duration, trends)
  - Hook trigger frequency
  - Skill trigger frequency & accuracy
  - Multiagent detection accuracy

Usage:
    python stats.py                    # summary dashboard
    python stats.py sessions           # session log list
    python stats.py hooks              # hook activity (from ERRORS.md)
    python stats.py skills             # SkillOpt feedback analysis
    python stats.py multiagent         # MultiAgentOpt analysis
    python stats.py trends             # session trends over time
    python stats.py --json             # output as JSON
    python stats.py --days 30          # filter to last N days
"""

import json
import os
import re
import sqlite3
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

# --- path resolution ---
SCRIPT_DIR = Path(__file__).resolve().parent
HARNESS_ROOT = Path(os.environ.get("HARNESS_ROOT", str(SCRIPT_DIR.parent.parent))).resolve()
CONFIG_DIR = HARNESS_ROOT / "config" if (HARNESS_ROOT / "config").exists() else HARNESS_ROOT
MEM_DB = HARNESS_ROOT / "data" / "claude-mem" / "claude-mem.db"
FEEDBACK_FILE = CONFIG_DIR / "training-loop" / "feedback.md"
ERRORS_FILE = CONFIG_DIR / "ERRORS.md"
META_FILE = CONFIG_DIR / "training-loop" / "meta.json"


def query_db(query: str, params: tuple = ()) -> list[tuple]:
    """Query the session log database."""
    if not MEM_DB.exists():
        return []
    try:
        conn = sqlite3.connect(str(MEM_DB))
        conn.row_factory = sqlite3.Row
        cur = conn.execute(query, params)
        rows = cur.fetchall()
        conn.close()
        return rows
    except Exception:
        return []


def parse_feedback_section(text: str, section: str) -> list[str]:
    """Extract entries from a feedback.md section."""
    block_re = rf"^##\s+{re.escape(section)}.*?(?=^##[^#]|\Z)"
    m = re.search(block_re, text, re.MULTILINE | re.DOTALL | re.IGNORECASE)
    if not m:
        return []
    block = m.group(0)
    entries = []
    for line in block.split("\n"):
        if line.startswith("### "):
            entries.append(line[4:].strip())
    return entries


def count_feedback_entries(text: str, section: str, labels: dict[str, str]) -> dict[str, int]:
    """Count TP/FP/FN entries under a ## section — same logic as training-collect.py."""
    block_re = rf"^##\s+{re.escape(section)}.*?(?=^##[^#]|\Z)"
    m = re.search(block_re, text, re.MULTILINE | re.DOTALL | re.IGNORECASE)
    block = m.group(0) if m else ""
    counts = {}
    for key, label in labels.items():
        pat = rf"^###\s+{re.escape(label)}(?:\s+.+|$)"
        counts[key] = len(re.findall(pat, block, re.MULTILINE))
    return counts


def parse_errors_md(text: str) -> list[dict]:
    """Parse ERRORS.md table into structured records."""
    entries = []
    for line in text.split("\n"):
        if line.startswith("|") and not line.startswith("|---") and "Timestamp" not in line:
            parts = [p.strip() for p in line.split("|")[1:-1]]
            if len(parts) >= 5:
                entries.append({
                    "timestamp": parts[0],
                    "hook": parts[1],
                    "duration": parts[2],
                    "exit_code": parts[3],
                    "error": parts[4],
                })
    return entries


def get_effective_session_count() -> int:
    """Get session count from meta.json (authoritative) or fall back to DB."""
    if META_FILE.exists():
        try:
            meta = json.loads(META_FILE.read_text(encoding="utf-8"))
            return meta.get("sessions", 0)
        except Exception:
            pass
    # Fallback: query DB directly
    rows = query_db("SELECT COUNT(*) as c FROM session_logs")
    return rows[0]["c"] if rows else 0


def cmd_sessions(days: int | None = None, json_output: bool = False):
    """Show session log statistics."""
    rows = query_db(
        "SELECT id, project, created_at, summary, files_touched FROM session_logs ORDER BY id DESC"
    )
    if not rows:
        effective = get_effective_session_count()
        if effective > 0:
            print(f"  Sessions: {effective} (from meta.json, no DB records accessible)")
        else:
            print("  No session logs found.")
        return

    if days:
        cutoff = datetime.now(timezone.utc) - timedelta(days=days)
        rows = [r for r in rows if r["created_at"] >= cutoff.isoformat()]

    if json_output:
        print(json.dumps([dict(r) for r in rows], indent=2, ensure_ascii=False))
        return

    effective = get_effective_session_count()
    db_count = len(rows)
    count_note = f"  Total sessions: {effective}" + (f" (DB has {db_count} rows)" if effective != db_count else "")
    print(count_note)
    print(f"  Date range: {rows[-1]['created_at'][:10]} to {rows[0]['created_at'][:10]}")
    print()

    for r in rows[:10]:
        print(f"  [#{r['id']}] {r['created_at'][:19]} | {r['project']} | {r['summary'][:60]}")

    if len(rows) > 10:
        print(f"  ... and {len(rows) - 10} more")


def cmd_hooks(days: int | None = None, json_output: bool = False):
    """Show hook error/activity statistics."""
    if not ERRORS_FILE.exists():
        print("  No ERRORS.md found.")
        return

    text = ERRORS_FILE.read_text(encoding="utf-8")
    entries = parse_errors_md(text)

    if days:
        cutoff = datetime.now(timezone.utc) - timedelta(days=days)
        entries = [e for e in entries if e["timestamp"] >= cutoff.isoformat()[:10]]

    if json_output:
        print(json.dumps(entries, indent=2, ensure_ascii=False))
        return

    if not entries:
        print("  No errors logged. Hooks are running clean.")
        return

    # Group by hook
    hook_counts = Counter(e["hook"] for e in entries)
    print(f"  Total errors: {len(entries)}")
    print(f"  Affected hooks: {len(hook_counts)}")
    print()
    print("  Errors by hook:")
    for hook, count in hook_counts.most_common():
        print(f"    {hook}: {count}")

    # Recent errors
    print()
    print("  Recent errors (last 5):")
    for e in entries[-5:]:
        print(f"    [{e['timestamp']}] {e['hook']} exit={e['exit_code']} ({e['error'][:40]})")


def cmd_skills(days: int | None = None, json_output: bool = False):
    """Show SkillOpt feedback analysis."""
    if not FEEDBACK_FILE.exists():
        print("  No training-loop/feedback.md found.")
        return

    text = FEEDBACK_FILE.read_text(encoding="utf-8")
    entries = parse_feedback_section(text, "SkillOpt")
    counts = count_feedback_entries(text, "SkillOpt", {"tp": "Correct Trigger", "fp": "False Positive", "fn": "Miss"})

    if json_output:
        print(json.dumps({"entries": entries, "counts": counts}, indent=2, ensure_ascii=False))
        return

    print(f"  SkillOpt entries: {len(entries)}")
    sub_counts = Counter(entries)
    for sub, count in sub_counts.most_common():
        print(f"    {sub}: {count}")
    print(f"  TP/FP/FN: {counts['tp']}/{counts['fp']}/{counts['fn']} (total signals: {sum(counts.values())})")

    # Also show meta.json if exists
    if META_FILE.exists():
        meta = json.loads(META_FILE.read_text(encoding="utf-8"))
        skill = meta.get("dimensions", {}).get("skill", {})
        if skill.get("metrics"):
            m = skill["metrics"]
            ema = skill.get("ema", {})
            print(f"\n  Metrics: P={m['precision']:.3f} R={m['recall']:.3f} F1={m['f1']:.3f}")
            if ema.get("f1"):
                print(f"  EMA: P={ema['precision']:.3f} R={ema['recall']:.3f} F1={ema['f1']:.3f}")
        if skill.get("weighted"):
            w = skill["weighted"]
            print(f"  Weighted F1: {w.get('weighted_f1', 'N/A')}")


def cmd_multiagent(days: int | None = None, json_output: bool = False):
    """Show MultiAgentOpt analysis."""
    if not FEEDBACK_FILE.exists():
        print("  No training-loop/feedback.md found.")
        return

    text = FEEDBACK_FILE.read_text(encoding="utf-8")
    entries = parse_feedback_section(text, "MultiAgentOpt")
    counts = count_feedback_entries(text, "MultiAgentOpt", {"tp": "Correct Trigger", "fp": "False Positive", "fn": "Miss"})

    if json_output:
        print(json.dumps({"entries": entries, "counts": counts}, indent=2, ensure_ascii=False))
        return

    print(f"  MultiAgentOpt entries: {len(entries)}")
    sub_counts = Counter(entries)
    for sub, count in sub_counts.most_common():
        print(f"    {sub}: {count}")
    print(f"  TP/FP/FN: {counts['tp']}/{counts['fp']}/{counts['fn']} (total signals: {sum(counts.values())})")

    if META_FILE.exists():
        meta = json.loads(META_FILE.read_text(encoding="utf-8"))
        ma = meta.get("dimensions", {}).get("multiagent", {})
        if ma.get("metrics"):
            m = ma["metrics"]
            ema = ma.get("ema", {})
            print(f"\n  Metrics: P={m['precision']:.3f} R={m['recall']:.3f} F1={m['f1']:.3f}")
            if ema.get("f1"):
                print(f"  EMA: P={ema['precision']:.3f} R={ema['recall']:.3f} F1={ema['f1']:.3f}")


def cmd_trends(days: int | None = None, json_output: bool = False):
    """Show session trends over time."""
    rows = query_db(
        "SELECT id, project, created_at, has_substance FROM session_logs ORDER BY id"
    )
    if not rows:
        print("  No session data for trend analysis.")
        return

    # Group by month
    monthly = Counter()
    for r in rows:
        month = r["created_at"][:7]
        monthly[month] += 1

    if json_output:
        print(json.dumps(dict(sorted(monthly.items())), indent=2))
        return

    print("  Sessions per month:")
    for month in sorted(monthly.keys()):
        bar = "█" * monthly[month]
        print(f"    {month}: {monthly[month]:3d} {bar}")

    print(f"\n  Total: {len(rows)} sessions")
    print(f"  Avg per month: {len(rows) / max(len(monthly), 1):.1f}")


def cmd_dashboard(days: int | None = None, json_output: bool = False):
    """Show a summary dashboard of all systems."""
    if json_output:
        data = {}

        # Sessions — use meta.json as authoritative source
        effective = get_effective_session_count()
        last = query_db("SELECT created_at FROM session_logs ORDER BY id DESC LIMIT 1")
        data["sessions"] = {"total": effective, "last": last[0]["created_at"] if last else None}

        # Errors
        if ERRORS_FILE.exists():
            text = ERRORS_FILE.read_text(encoding="utf-8")
            entries = parse_errors_md(text)
            data["errors"] = {"total": len(entries)}
        else:
            data["errors"] = {"total": 0}

        # Feedback counts
        if FEEDBACK_FILE.exists():
            text = FEEDBACK_FILE.read_text(encoding="utf-8")
            dim_labels = {
                "SkillOpt": {"tp": "Correct Trigger", "fp": "False Positive", "fn": "Miss"},
                "MultiAgentOpt": {"tp": "Correct Trigger", "fp": "False Positive", "fn": "Miss"},
                "ToolCallOpt": {"tp": "Positive", "fp": "Negative", "fn": "Missed Opportunity"},
            }
            for section in ["SkillOpt", "MultiAgentOpt", "ToolCallOpt"]:
                labels = dim_labels[section]
                counts = count_feedback_entries(text, section, labels)
                data[section] = {"entries": len(parse_feedback_section(text, section)), "counts": counts}

        # Meta
        if META_FILE.exists():
            meta = json.loads(META_FILE.read_text(encoding="utf-8"))
            data["meta"] = meta

        print(json.dumps(data, indent=2, ensure_ascii=False, default=str))
        return

    rows = query_db("SELECT COUNT(*) as c FROM session_logs")
    session_count = get_effective_session_count()

    print(f"  Sessions logged: {session_count}")
    print()

    # Last session
    last = query_db("SELECT created_at, summary FROM session_logs ORDER BY id DESC LIMIT 1")
    if last:
        print(f"  Last session: {last[0]['created_at'][:19]}")
        print(f"  Summary: {last[0]['summary'][:80]}")

    print()

    # Error count
    error_count = 0
    if ERRORS_FILE.exists():
        text = ERRORS_FILE.read_text(encoding="utf-8")
        error_count = len(parse_errors_md(text))
    print(f"  Hook errors: {error_count}")
    print()

    # Feedback summary
    if FEEDBACK_FILE.exists():
        text = FEEDBACK_FILE.read_text(encoding="utf-8")
        for section in ["SkillOpt", "MultiAgentOpt", "ToolCallOpt"]:
            entries = parse_feedback_section(text, section)
            print(f"  {section}: {len(entries)} observations")
    print()

    # Multiagent threshold
    if META_FILE.exists():
        meta = json.loads(META_FILE.read_text(encoding="utf-8"))
        ma = meta.get("dimensions", {}).get("multiagent", {})
        ema_f1 = ma.get("ema", {}).get("f1")
        if ema_f1:
            print(f"  MultiAgent F1 (EMA): {ema_f1:.3f}")
        last_opt = meta.get("last_optimized", "")
        if last_opt:
            print(f"  Last optimized: {last_opt[:19] if len(last_opt) > 19 else last_opt}")


def main():
    import argparse
    parser = argparse.ArgumentParser(description="lean-hooks stats CLI")
    parser.add_argument("command", nargs="?", default="dashboard",
                        choices=["dashboard", "sessions", "hooks", "skills", "multiagent", "trends"],
                        help="Stats command (default: dashboard)")
    parser.add_argument("--json", action="store_true", help="JSON output")
    parser.add_argument("--days", type=int, help="Filter to last N days")
    args = parser.parse_args()

    commands = {
        "dashboard": cmd_dashboard,
        "sessions": cmd_sessions,
        "hooks": cmd_hooks,
        "skills": cmd_skills,
        "multiagent": cmd_multiagent,
        "trends": cmd_trends,
    }

    fn = commands.get(args.command, cmd_dashboard)
    fn(days=args.days, json_output=args.json)


if __name__ == "__main__":
    main()