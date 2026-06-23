#!/usr/bin/env python
"""Loop Readiness Audit — scores project loop readiness (0-100) and assigns level L0-L3.

Ops:
  --dir <path>       Project root to audit (default: HARNESS_ROOT)
  --json             Machine-readable output
  --suggest          Include suggestions for gaps
  --quick            Fast 3-point check (state, budget, run-log recency)

Scoring rubric (100 total):
  State files  15, Skills 15, Maker/Checker 10, Budget 10, Run logs 10,
  Safety docs 10, MCP connectors 5, Worktree evidence 5,
  Loop activity 10, Training feedback 10

Levels: L0(0-39), L1(40-64), L2(65-84), L3(85-100)
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


def _detect_paths(harness_root=None):
    if not harness_root:
        harness_root = os.environ.get("HARNESS_ROOT", "")
    if not harness_root:
        script_dir = os.path.dirname(os.path.abspath(__file__))
        parent = os.path.dirname(script_dir)
        if os.path.basename(parent) == "config":
            harness_root = os.path.dirname(parent)
        else:
            harness_root = parent

    config_dir = os.path.join(harness_root, "config") if os.path.isdir(os.path.join(harness_root, "config")) else harness_root
    loop_eng_dir = os.path.join(config_dir, "loop-engineering")
    states_dir = os.path.join(loop_eng_dir, "states")
    run_log = os.path.join(loop_eng_dir, "run-log.jsonl")
    budget = os.path.join(loop_eng_dir, "budget.json")
    safety = os.path.join(loop_eng_dir, "safety.md")
    loop_md = os.path.join(loop_eng_dir, "LOOP.md")
    registry = os.path.join(loop_eng_dir, "patterns", "registry.yaml")
    meta = os.path.join(config_dir, "training-loop", "meta.json")
    settings = os.path.join(config_dir, "settings.json")
    skills_dir = os.path.join(config_dir, "skills")

    return {
        "harness_root": harness_root,
        "config_dir": config_dir,
        "loop_eng_dir": loop_eng_dir,
        "states_dir": states_dir,
        "run_log": run_log,
        "budget": budget,
        "safety": safety,
        "loop_md": loop_md,
        "registry": registry,
        "meta": meta,
        "settings": settings,
        "skills_dir": skills_dir,
    }


def _score_state_files(paths):
    """15 pts: per-pattern state exists under states/"""
    if not os.path.isdir(paths["states_dir"]):
        return 0, "states/ directory missing"
    found = [f for f in os.listdir(paths["states_dir"]) if f.endswith(".json")] if os.path.isdir(paths["states_dir"]) else []
    n = len(found)
    pts = min(15, int(15 * n / max(len(KNOWN_PATTERNS), 1)))
    detail = f"{n}/{len(KNOWN_PATTERNS)} pattern states found"
    return pts, detail


def _score_skills(paths):
    """15 pts: referenced skills exist in config/skills/"""
    if not os.path.isdir(paths["skills_dir"]):
        return 0, "skills/ directory missing"
    # Check core skills used by loop patterns
    required = ["issue-triage", "babysit", "systematic-debugging", "verification-before-completion",
                "security-guardian", "repo-recap", "finishing-a-development-branch",
                "requesting-code-review"]
    found = []
    for s in required:
        if os.path.isdir(os.path.join(paths["skills_dir"], s)):
            found.append(s)
    n = len(found)
    pts = min(15, int(15 * n / len(required)))
    return pts, f"{n}/{len(required)} required skills present"


def _score_maker_checker(paths):
    """10 pts: registry.yaml references distinct maker + checker skills"""
    registry = paths["registry"]
    if not os.path.isfile(registry):
        return 0, "registry.yaml not found"
    try:
        with open(registry, encoding="utf-8") as f:
            content = f.read()
    except Exception:
        return 0, "Cannot read registry.yaml"

    # Simple YAML parse: count patterns with maker + checker
    has_maker = "maker:" in content
    has_checker = "checker:" in content
    if has_maker and has_checker:
        return 10, "Maker/checker split defined in registry"
    elif has_maker or has_checker:
        return 5, "Partial maker/checker definition"
    return 0, "No maker/checker split in registry"


def _score_budget(paths):
    """10 pts: budget.json exists with caps"""
    budget = paths["budget"]
    if not os.path.isfile(budget):
        return 0, "budget.json missing"
    try:
        with open(budget, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return 2, "budget.json exists but invalid JSON"

    caps = ["daily_token_cap" in data, "daily_run_cap" in data, "cost_per_pattern" in data]
    n = sum(caps)
    pts = int(10 * n / max(len(caps), 1))
    return pts, f"budget.json present with {n}/3 cap sections"


def _score_run_logs(paths):
    """10 pts: run-log.jsonl exists with entries"""
    run_log = paths["run_log"]
    if not os.path.isfile(run_log):
        return 0, "run-log.jsonl missing"
    try:
        with open(run_log, encoding="utf-8") as f:
            lines = [l.strip() for l in f if l.strip()]
    except Exception:
        return 2, "run-log.jsonl exists but unreadable"

    n = len(lines)
    if n >= 10:
        return 10, f"run-log.jsonl has {n} entries"
    elif n > 0:
        return int(10 * n / 10), f"run-log.jsonl has {n} entries (need 10 for full score)"
    return 3, "run-log.jsonl exists but empty"


def _score_safety(paths):
    """10 pts: safety.md or LOOP.md safety section"""
    safety = paths["safety"]
    loop_md = paths["loop_md"]

    if os.path.isfile(safety):
        try:
            with open(safety, encoding="utf-8") as f:
                content = f.read()
            keywords = ["denylist", "auto-merge", "kill switch", "escalation"]
            found = sum(1 for k in keywords if k.lower() in content.lower())
            pts = min(10, int(10 * found / len(keywords)))
            return pts, f"safety.md with {found}/{len(keywords)} policy sections"
        except Exception:
            return 3, "safety.md exists but unreadable"

    if os.path.isfile(loop_md):
        try:
            with open(loop_md, encoding="utf-8") as f:
                content = f.read()
            if "safety" in content.lower():
                return 5, "LOOP.md has safety section (dedicated safety.md preferred)"
        except Exception:
            pass

    return 0, "No safety documentation found"


def _score_mcp(paths):
    """5 pts: MCP servers configured in settings.json"""
    settings = paths["settings"]
    if not os.path.isfile(settings):
        return 0, "settings.json not found"
    try:
        with open(settings, encoding="utf-8") as f:
            data = json.load(f)
        # Check for MCP config in various locations
        mcp_config = data.get("mcpServers", data.get("mcp", {}))
        n = len(mcp_config)
        if n > 0:
            return 5, f"{n} MCP server(s) configured"
    except Exception:
        pass
    return 0, "No MCP servers found in settings.json"


def _score_worktree(paths):
    """5 pts: worktree evidence"""
    harness_root = paths["harness_root"]
    worktree_dir = os.path.join(harness_root, ".claude", "worktrees")
    if os.path.isdir(worktree_dir):
        entries = os.listdir(worktree_dir)
        if entries:
            return 5, f".claude/worktrees/ has {len(entries)} entries"
    return 0, "No worktree evidence found"


def _score_activity(paths):
    """10 pts: run log has entries within last cadence"""
    run_log = paths["run_log"]
    if not os.path.isfile(run_log):
        return 0, "No run log for activity check"

    try:
        with open(run_log, encoding="utf-8") as f:
            lines = [l.strip() for l in f if l.strip()]
    except Exception:
        return 0, "Cannot read run log"

    if not lines:
        return 0, "Run log is empty"

    # Check for entries in the last 24h
    now = datetime.now(timezone.utc)
    cutoff = (now - timedelta(hours=48)).isoformat()
    recent = 0
    for line in lines[-50:]:
        try:
            entry = json.loads(line)
            if entry.get("started_at", "") >= cutoff:
                recent += 1
        except Exception:
            pass

    if recent > 0:
        return 10, f"{recent} recent run(s) in last 48h"
    return 3, "Run log has entries but none recent"


def _score_training(paths):
    """10 pts: training-loop meta.json with v2.1 EMA"""
    meta = paths["meta"]
    if not os.path.isfile(meta):
        return 2, "meta.json not found"

    try:
        with open(meta, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        return 2, "meta.json exists but unreadable"

    if data.get("version") == "2.1":
        dims = data.get("dimensions", {})
        has_ema = any(d.get("ema", {}).get("f1") is not None for d in dims.values())
        if has_ema:
            return 10, "meta.json v2.1 with EMA metrics"
        return 7, "meta.json v2.1 but missing EMA"

    return 5, f"meta.json present (version: {data.get('version', 'unknown')})"


def _assign_level(score):
    if score >= 85:
        return "L3"
    elif score >= 65:
        return "L2"
    elif score >= 40:
        return "L1"
    return "L0"


def run_audit(harness_root=None, suggest=False, quick=False):
    paths = _detect_paths(harness_root)

    if quick:
        # Fast 3-point check: state dir, budget, run-log recent
        state_ok = os.path.isdir(paths["states_dir"])
        budget_ok = os.path.isfile(paths["budget"])
        log_recent = False
        if os.path.isfile(paths["run_log"]):
            try:
                mtime = os.path.getmtime(paths["run_log"])
                if (datetime.now().timestamp() - mtime) < 86400 * 2:
                    log_recent = True
            except Exception:
                pass
        score = sum([state_ok * 34, budget_ok * 33, log_recent * 33])
        return {"score": score, "level": _assign_level(score), "quick": True}

    checks = [
        ("state_files", _score_state_files, 15),
        ("skills", _score_skills, 15),
        ("maker_checker", _score_maker_checker, 10),
        ("budget", _score_budget, 10),
        ("run_logs", _score_run_logs, 10),
        ("safety", _score_safety, 10),
        ("mcp_connectors", _score_mcp, 5),
        ("worktree", _score_worktree, 5),
        ("activity", _score_activity, 10),
        ("training", _score_training, 10),
    ]

    results = []
    total = 0
    for name, fn, max_pts in checks:
        pts, detail = fn(paths)
        results.append({"category": name, "points": pts, "max": max_pts, "detail": detail})
        total += pts

    level = _assign_level(total)

    output = {
        "score": total,
        "level": level,
        "checks": results,
    }

    if suggest:
        suggestions = []
        for c in results:
            if c["points"] < c["max"]:
                gap = c["max"] - c["points"]
                if gap >= 5:
                    if c["category"] == "state_files":
                        suggestions.append(f"Create state files for patterns: {', '.join(KNOWN_PATTERNS)}")
                    elif c["category"] == "maker_checker":
                        suggestions.append("Add maker_skill and checker_skill to registry.yaml patterns")
                    elif c["category"] == "budget":
                        suggestions.append("Add daily_token_cap, daily_run_cap, and cost_per_pattern to budget.json")
                    elif c["category"] == "run_logs":
                        suggestions.append("Run a loop pattern to populate run-log.jsonl")
                    elif c["category"] == "safety":
                        suggestions.append("Create safety.md with path denylist, auto-merge policy, escalation rules")
                    elif c["category"] == "activity":
                        suggestions.append("Run loop patterns regularly to build activity history")
                    elif c["category"] == "worktree":
                        suggestions.append("Use git worktrees for isolated loop execution")
                    elif c["category"] == "mcp_connectors":
                        suggestions.append("Configure MCP servers in settings.json for external tool access")
                    elif c["category"] == "training":
                        suggestions.append("Ensure training-loop/meta.json has v2.1 with EMA metrics")
                    elif c["category"] == "skills":
                        suggestions.append("Install missing skills: issue-triage, babysit, systematic-debugging, etc.")
        output["suggestions"] = suggestions

    return output


def main():
    parser = argparse.ArgumentParser(description="Loop Readiness Audit")
    parser.add_argument("--dir", help="Project root directory")
    parser.add_argument("--json", action="store_true", help="Machine-readable output")
    parser.add_argument("--suggest", action="store_true", help="Include improvement suggestions")
    parser.add_argument("--quick", action="store_true", help="Fast 3-point check")
    args = parser.parse_args()

    harness_root = args.dir or None
    result = run_audit(harness_root=harness_root, suggest=args.suggest, quick=args.quick)

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print(f"\nLoop Readiness Audit")
        print(f"{'='*40}")
        print(f"Score: {result['score']}/100")
        print(f"Level: {result['level']}")
        if "checks" in result:
            print(f"\n{'Category':<20} {'Pts':>5} {'Max':>5}  Detail")
            print(f"{'-'*60}")
            for c in result["checks"]:
                print(f"{c['category']:<20} {c['points']:>5} {c['max']:>5}  {c['detail']}")
        if "suggestions" in result and result["suggestions"]:
            print(f"\nSuggestions:")
            for s in result["suggestions"]:
                print(f"  - {s}")


if __name__ == "__main__":
    main()
