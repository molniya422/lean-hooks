#!/usr/bin/env python3
"""Role-Collab Runner — executes the parallel-gate protocol for multi-role agent collaboration.

Phases: IMPLEMENT → parallel(REVIEW, TEST, ARCHITECT_CHECK) → DECISION
Each role is dispatched as a separate sub-agent. Verdicts are collected,
veto rules applied, and the review cycle repeats (max 3) or escalates.

Usage:
  role-collab-runner.py run --task "description" [--level L1|L2] [--dry-run]
  role-collab-runner.py status [--task-id ID]
  role-collab-runner.py list-roles

Integration: loop-run-logger, loop-budget-tracker, loop-state-manager
"""
import argparse
import json
import os
import sys
import uuid
from datetime import datetime, timezone

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

PATTERN = "role-collab"
MAX_REVIEW_CYCLES = 3

ROLE_DEFS = {
    "maker": {
        "description": "Implements the code change",
        "prompt_template": (
            "You are the MAKER role in a role-collab workflow.\n"
            "Task: {task}\n\n"
            "Implement the code change. Write clean, tested code.\n"
            "Follow test-driven-development: write tests first, then implement.\n"
            "Output ONLY the code changes (file paths and content).\n"
            "Do NOT review your own work — that's the Reviewer's job."
        ),
    },
    "reviewer": {
        "description": "Reviews code for correctness, style, security",
        "prompt_template": (
            "You are the REVIEWER role in a role-collab workflow.\n"
            "Task: {task}\n"
            "Maker's changes:\n{maker_output}\n\n"
            "Review the code changes for:\n"
            "- Correctness: does it solve the task?\n"
            "- Style: does it match project conventions?\n"
            "- Security: any vulnerabilities introduced?\n"
            "- Completeness: are edge cases handled?\n\n"
            "Output JSON: {{\"verdict\": \"APPROVE\"|\"REQUEST_CHANGES\", \"issues\": [\"...\"], \"summary\": \"...\"}}"
        ),
    },
    "tester": {
        "description": "Runs tests and verifies behavior",
        "prompt_template": (
            "You are the TESTER role in a role-collab workflow.\n"
            "Task: {task}\n"
            "Maker's changes:\n{maker_output}\n\n"
            "Run the relevant tests. If no tests exist, write and run them.\n"
            "Output JSON: {{\"verdict\": \"PASS\"|\"FAIL\", \"test_results\": \"...\", \"failures\": [...]}}"
        ),
    },
    "architect": {
        "description": "Checks architectural compliance and cross-file impact",
        "prompt_template": (
            "You are the ARCHITECT role in a role-collab workflow.\n"
            "Task: {task}\n"
            "Maker's changes:\n{maker_output}\n\n"
            "Evaluate:\n"
            "- Architectural compliance: does this fit the project's design?\n"
            "- Cross-file impact: what else is affected?\n"
            "- Risk assessment: could this change break other components?\n\n"
            "Output JSON: {{\"verdict\": \"SAFE\"|\"RISK\", \"concerns\": [...], \"impact_scope\": \"...\"}}"
        ),
    },
}


def _detect_paths():
    config_dir = os.environ.get("CONFIG_DIR", "")
    if not config_dir:
        harness_root = os.environ.get("HARNESS_ROOT", "")
        if harness_root:
            candidate = os.path.join(harness_root, "config")
            config_dir = candidate if os.path.isdir(candidate) else harness_root
        else:
            script_dir = os.path.dirname(os.path.abspath(__file__))
            parent = os.path.dirname(script_dir)
            config_dir = parent if os.path.basename(parent) == "config" else script_dir
    loop_eng_dir = os.environ.get("LOOP_ENG_DIR", os.path.join(config_dir, "loop-engineering"))
    return {
        "state": os.path.join(loop_eng_dir, "states", f"{PATTERN}.json"),
        "budget": os.path.join(loop_eng_dir, "budget.json"),
        "run_log": os.path.join(loop_eng_dir, "run-log.jsonl"),
        "registry": os.path.join(loop_eng_dir, "patterns", "registry.yaml"),
    }


def _load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def _save_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def _check_budget(paths):
    budget = _load_json(paths["budget"])
    if not budget:
        return {"status": "ok", "message": "No budget file"}
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    cap = budget.get("daily_token_cap", 500000)
    usage = budget.get("daily_usage", {}).get(today, {})
    tokens = usage.get("tokens_used", 0)
    pct = round(tokens / cap * 100, 1) if cap > 0 else 0
    if pct >= 100:
        return {"status": "kill", "pct": pct}
    if pct >= 80:
        return {"status": "warning", "pct": pct}
    return {"status": "ok", "pct": pct}


def _record_budget(paths, tokens, run_id):
    budget = _load_json(paths["budget"])
    if not budget:
        return
    today = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    if "daily_usage" not in budget:
        budget["daily_usage"] = {}
    if today not in budget["daily_usage"]:
        budget["daily_usage"][today] = {"tokens_used": 0, "runs": 0, "by_pattern": {}}
    du = budget["daily_usage"][today]
    du["tokens_used"] = du.get("tokens_used", 0) + tokens
    du["runs"] = du.get("runs", 0) + 1
    bp = du.get("by_pattern", {})
    bp[PATTERN] = bp.get(PATTERN, 0) + 1
    du["by_pattern"] = bp
    _save_json(paths["budget"], budget)


def _log_run(paths, run_id, started_at, ended_at, outcome, token_est, roles_output, cycle_count):
    entry = {
        "run_id": run_id,
        "pattern": PATTERN,
        "started_at": started_at,
        "ended_at": ended_at,
        "outcome": outcome,
        "token_estimate": token_est,
        "roles_output": roles_output,
        "review_cycles": cycle_count,
        "duration_seconds": 0,
    }
    log_path = paths["run_log"]
    os.makedirs(os.path.dirname(log_path), exist_ok=True)
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


def _update_state(paths, updates):
    state = _load_json(paths["state"])
    if not state:
        state = {"pattern": PATTERN, "status": "active", "readiness_level": "L0"}
    state.update(updates)
    state["updated_at"] = datetime.now(timezone.utc).isoformat()
    _save_json(paths["state"], state)
    return state


def _apply_veto_rules(verdicts):
    """Apply the veto rules from the coordination protocol.

    Returns: (decision, reason)
      decision: "accept" | "reject" | "revise" | "escalate_risk" | "escalate_veto"
    """
    tester = verdicts.get("tester", {})
    architect = verdicts.get("architect", {})
    reviewer = verdicts.get("reviewer", {})

    # Rule 1: Tester FAIL → mandatory reject
    if tester.get("verdict") == "FAIL":
        issues = tester.get("failures", [])
        return "reject", f"Tester FAIL: {', '.join(issues[:3])}"

    # Rule 2: Architect RISK → escalate to human
    if architect.get("verdict") == "RISK":
        concerns = architect.get("concerns", [])
        return "escalate_risk", f"Architect RISK: {', '.join(concerns[:3])}"

    # Rule 3: Reviewer REJECT
    if reviewer.get("verdict") == "REQUEST_CHANGES":
        issues = reviewer.get("issues", [])
        return "revise", f"Reviewer requests changes: {', '.join(issues[:3])}"

    # All pass
    if reviewer.get("verdict") == "APPROVE" and tester.get("verdict") == "PASS" and architect.get("verdict") == "SAFE":
        return "accept", "All roles approve"

    # Partial — default to revise if reviewer hasn't explicitly approved
    return "revise", "Partial approval — reviewer needs to clarify"


def _build_agent_prompts(task, maker_output=None):
    """Build the prompt strings for each role agent."""
    prompts = {}
    for role, defn in ROLE_DEFS.items():
        template = defn["prompt_template"]
        if role == "maker":
            prompts[role] = template.format(task=task)
        else:
            prompts[role] = template.format(
                task=task,
                maker_output=maker_output or "(Maker has not yet produced output)",
            )
    return prompts


def cmd_run(task, level="L1", dry_run=False):
    paths = _detect_paths()
    run_id = f"rc-{uuid.uuid4().hex[:8]}"
    started_at = datetime.now(timezone.utc).isoformat()

    # Budget check
    budget_status = _check_budget(paths)
    if budget_status["status"] == "kill":
        print(json.dumps({"error": "Budget exhausted", "budget_status": budget_status}, indent=2))
        return

    # Load current state
    state = _load_json(paths["state"]) or {}
    active_tasks = state.get("active_tasks", [])

    # Initialize task record
    task_record = {
        "task_id": run_id,
        "description": task,
        "level": level,
        "started_at": started_at,
        "status": "in_progress",
        "cycle": 0,
        "verdicts": {},
        "decision": None,
    }
    active_tasks.append(task_record)
    _update_state(paths, {"active_tasks": active_tasks, "last_run": started_at, "last_run_id": run_id})

    prompts = _build_agent_prompts(task)
    token_estimate = 0

    if level == "L1":
        # L1: propose-only — output the plan without dispatching agents
        result = {
            "run_id": run_id,
            "level": "L1",
            "task": task,
            "phase": "PROPOSE_ONLY",
            "proposed_roles": list(ROLE_DEFS.keys()),
            "proposed_flow": ["IMPLEMENT", "REVIEW+TEST+ARCHITECT_CHECK (parallel)", "DECISION"],
            "prompts_preview": {k: v[:150] + "..." for k, v in prompts.items()},
            "token_estimate": 30000,
            "message": "L1: No agents dispatched. Review the proposed plan.",
        }
        token_estimate = 1000  # minimal tokens for L1
        _log_run(paths, run_id, started_at, datetime.now(timezone.utc).isoformat(),
                 "success_l1", token_estimate, {}, 0)
        _record_budget(paths, token_estimate, run_id)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return

    # L2+: Execute the protocol
    if dry_run:
        result = {
            "run_id": run_id,
            "level": level,
            "task": task,
            "phase": "DRY_RUN",
            "prompts": prompts,
            "coordination_protocol": "parallel_gate",
            "max_review_cycles": MAX_REVIEW_CYCLES,
            "veto_rules": [
                "tester FAIL → reject",
                "architect RISK → escalate to human",
                "reviewer REQUEST_CHANGES → revise",
            ],
            "message": "Dry run complete. No agents dispatched.",
        }
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return

    # Real execution — output agent dispatch instructions
    # (Claude Code orchestrator will use these to dispatch Agent tool calls)
    cycle = 0
    maker_output = None
    final_decision = None
    final_reason = None
    all_verdicts = {}
    consecutive_vetoes = 0

    # Phase 1: IMPLEMENT — dispatch Maker agent
    print(f"[role-collab] Cycle {cycle + 1}/{MAX_REVIEW_CYCLES}: IMPLEMENT phase")
    print(f"[role-collab] Dispatch MAKER agent with prompt:")
    print(f"---MAKER_PROMPT_START---")
    print(prompts["maker"])
    print(f"---MAKER_PROMPT_END---")
    print()
    print(f"[role-collab] ⏸ Waiting for MAKER output before dispatching REVIEW/TEST/ARCHITECT agents...")
    print(f"[role-collab] After Maker completes, run: role-collab-runner.py review --task-id {run_id} --maker-output '<output>'")

    # Update state
    task_record["cycle"] = cycle + 1
    active_tasks = [t for t in active_tasks if t["task_id"] != run_id] + [task_record]
    _update_state(paths, {"active_tasks": active_tasks})


def cmd_review(task_id, maker_output, level="L2"):
    """Execute the parallel REVIEW phase after Maker completes."""
    paths = _detect_paths()
    state = _load_json(paths["state"]) or {}
    active_tasks = state.get("active_tasks", [])
    task_record = next((t for t in active_tasks if t["task_id"] == task_id), None)

    if not task_record:
        print(json.dumps({"error": f"Task {task_id} not found in active tasks"}, indent=2))
        return

    task = task_record["description"]
    prompts = _build_agent_prompts(task, maker_output)

    # Dispatch 3 parallel agents: Reviewer, Tester, Architect
    print(f"[role-collab] Dispatching PARALLEL agents: REVIEWER, TESTER, ARCHITECT")
    for role in ["reviewer", "tester", "architect"]:
        print(f"---{role.upper()}_PROMPT_START---")
        print(prompts[role])
        print(f"---{role.upper()}_PROMPT_END---")
        print()

    print(f"[role-collab] ⏸ Waiting for all 3 verdicts...")
    print(f"[role-collab] After all verdicts arrive, run: role-collab-runner.py decide --task-id {task_id} --reviewer-verdict '<json>' --tester-verdict '<json>' --architect-verdict '<json>'")

    task_record["maker_output"] = maker_output
    active_tasks = [t for t in active_tasks if t["task_id"] != task_id] + [task_record]
    _update_state(paths, {"active_tasks": active_tasks})


def cmd_decide(task_id, reviewer_verdict, tester_verdict, architect_verdict, level="L2"):
    """Apply veto rules and make the DECISION."""
    paths = _detect_paths()
    state = _load_json(paths["state"]) or {}
    active_tasks = state.get("active_tasks", [])
    task_record = next((t for t in active_tasks if t["task_id"] == task_id), None)

    if not task_record:
        print(json.dumps({"error": f"Task {task_id} not found"}, indent=2))
        return

    cycle = task_record.get("cycle", 0)
    verdicts = {
        "reviewer": reviewer_verdict,
        "tester": tester_verdict,
        "architect": architect_verdict,
    }
    decision, reason = _apply_veto_rules(verdicts)

    # Track consecutive vetoes
    prev_vetoes = state.get("total_vetoes", 0)
    if decision in ("reject", "revise"):
        prev_vetoes += 1
    else:
        prev_vetoes = 0

    result = {
        "task_id": task_id,
        "cycle": cycle,
        "decision": decision,
        "reason": reason,
        "verdicts": verdicts,
        "consecutive_vetoes": prev_vetoes,
    }

    # Escalation checks
    if decision == "escalate_risk":
        result["action"] = "ESCALATE_TO_HUMAN"
        result["escalation_reason"] = "Architect RISK verdict — human approval required"
    elif prev_vetoes >= 2:
        result["action"] = "ESCALATE_TO_HUMAN"
        result["escalation_reason"] = f"{prev_vetoes} consecutive vetoes — human approval required"
    elif decision == "reject":
        result["action"] = "REJECT"
        result["message"] = "Tests failed. Maker must fix before re-review."
    elif decision == "revise" and cycle < MAX_REVIEW_CYCLES:
        result["action"] = "REVISE"
        result["message"] = f"Request changes (cycle {cycle}/{MAX_REVIEW_CYCLES}). Re-dispatch Maker."
    elif decision == "revise" and cycle >= MAX_REVIEW_CYCLES:
        result["action"] = "ESCALATE_TO_HUMAN"
        result["escalation_reason"] = f"Max review cycles ({MAX_REVIEW_CYCLES}) reached"
    elif decision == "accept":
        result["action"] = "ACCEPT"
        result["message"] = "All roles approved. Changes can be merged."
    else:
        result["action"] = "ESCALATE_TO_HUMAN"
        result["escalation_reason"] = "Indeterminate state — human review needed"

    # L2: require human confirmation
    if level == "L2" and decision == "accept":
        result["action"] = "PENDING_HUMAN_APPROVAL"
        result["message"] = "All roles approved. Waiting for human confirmation to merge."

    # Update state
    task_record["verdicts"] = verdicts
    task_record["decision"] = decision
    task_record["cycle"] = cycle + 1 if decision == "revise" else cycle
    task_record["status"] = "completed" if decision == "accept" else task_record.get("status")
    active_tasks = [t for t in active_tasks if t["task_id"] != task_id] + [task_record]

    # Log and budget
    token_est = 30000
    ended_at = datetime.now(timezone.utc).isoformat()
    _log_run(paths, task_id, task_record.get("started_at", ""), ended_at,
             decision, token_est, verdicts, cycle)

    if decision in ("accept", "reject"):
        # Move from active to resolved
        active_tasks = [t for t in active_tasks if t["task_id"] != task_id]
        resolved = state.get("resolved_items", [])
        resolved.append(task_record)
        _update_state(paths, {
            "active_tasks": active_tasks,
            "resolved_items": resolved,
            "total_vetoes": prev_vetoes,
            "total_review_cycles": state.get("total_review_cycles", 0) + cycle,
            "total_runs": state.get("total_runs", 0) + 1,
            "total_successes": state.get("total_successes", 0) + (1 if decision == "accept" else 0),
        })
        _record_budget(paths, token_est, task_id)
    else:
        _update_state(paths, {
            "active_tasks": active_tasks,
            "total_vetoes": prev_vetoes,
            "total_review_cycles": state.get("total_review_cycles", 0) + cycle,
        })

    print(json.dumps(result, indent=2, ensure_ascii=False))


def cmd_status(task_id=None):
    """Show current role-collab state."""
    paths = _detect_paths()
    state = _load_json(paths["state"])
    if not state:
        print(json.dumps({"error": "No state file found"}, indent=2))
        return

    if task_id:
        active = state.get("active_tasks", [])
        resolved = state.get("resolved_items", [])
        for t in active + resolved:
            if t.get("task_id") == task_id:
                print(json.dumps(t, indent=2, ensure_ascii=False))
                return
        print(json.dumps({"error": f"Task {task_id} not found"}, indent=2))
    else:
        result = {
            "pattern": PATTERN,
            "readiness_level": state.get("readiness_level", "L0"),
            "active_tasks": len(state.get("active_tasks", [])),
            "resolved_tasks": len(state.get("resolved_items", [])),
            "escalated_items": len(state.get("escalated_items", [])),
            "total_runs": state.get("total_runs", 0),
            "total_vetoes": state.get("total_vetoes", 0),
            "total_review_cycles": state.get("total_review_cycles", 0),
        }
        print(json.dumps(result, indent=2, ensure_ascii=False))


def cmd_list_roles():
    """List all role definitions."""
    roles = []
    for name, defn in ROLE_DEFS.items():
        roles.append({"role": name, "description": defn["description"]})
    print(json.dumps(roles, indent=2, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description="Role-Collab Runner")
    sub = parser.add_subparsers(dest="command")

    # run
    run_p = sub.add_parser("run", help="Execute a role-collab workflow")
    run_p.add_argument("--task", required=True, help="Task description")
    run_p.add_argument("--level", default="L1", choices=["L1", "L2", "L3"])
    run_p.add_argument("--dry-run", action="store_true")

    # review
    rev_p = sub.add_parser("review", help="Dispatch parallel review agents")
    rev_p.add_argument("--task-id", required=True)
    rev_p.add_argument("--maker-output", required=True)
    rev_p.add_argument("--level", default="L2")

    # decide
    dec_p = sub.add_parser("decide", help="Apply veto rules and decide")
    dec_p.add_argument("--task-id", required=True)
    dec_p.add_argument("--reviewer-verdict", required=True)
    dec_p.add_argument("--tester-verdict", required=True)
    dec_p.add_argument("--architect-verdict", required=True)
    dec_p.add_argument("--level", default="L2")

    # status
    sub.add_parser("status", help="Show role-collab state")
    stat_p = sub.add_parser("task", help="Show specific task")
    stat_p.add_argument("--task-id", required=True)

    # list-roles
    sub.add_parser("list-roles", help="List role definitions")

    args = parser.parse_args()

    if args.command == "run":
        cmd_run(args.task, args.level, args.dry_run)
    elif args.command == "review":
        cmd_review(args.task_id, args.maker_output, args.level)
    elif args.command == "decide":
        def _parse_verdict(v):
            if not v:
                return {"verdict": ""}
            v = v.strip()
            if v.startswith("{"):
                try:
                    return json.loads(v)
                except json.JSONDecodeError:
                    return {"verdict": v}
            return {"verdict": v}
        cmd_decide(
            args.task_id,
            _parse_verdict(args.reviewer_verdict),
            _parse_verdict(args.tester_verdict),
            _parse_verdict(args.architect_verdict),
            args.level,
        )
    elif args.command == "status":
        cmd_status()
    elif args.command == "task":
        cmd_status(args.task_id)
    elif args.command == "list-roles":
        cmd_list_roles()
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
