#!/usr/bin/env python
"""Loop Checklist Validator — validates loop design against 10-section checklist.

10 sections:
  1. purpose        Required for L1+
  2. scheduling      Required for L1+
  3. skills          Required for L1+
  4. maker_checker   Required for L2+
  5. state           Required for L1+
  6. human_handoff   Required for L1+
  7. connectors      Required for L2+
  8. cost            Required for L1+
  9. observability   Required for L2+
  10. safety          Required for L3

Input: registry.yaml pattern entry (or a standalone JSON/YAML pattern definition)
Output: {pattern, checklist, achieved_level, blocking_for_l2, blocking_for_l3}
"""
import argparse
import json
import os
import sys

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

SECTION_LEVELS = {
    "purpose": "L1",
    "scheduling": "L1",
    "skills": "L1",
    "maker_checker": "L2",
    "state": "L1",
    "human_handoff": "L1",
    "connectors": "L2",
    "cost": "L1",
    "observability": "L2",
    "safety": "L3",
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
    return os.path.join(loop_eng_dir, "patterns", "registry.yaml")


def _parse_registry_simple(path):
    """Simple YAML parser for pattern entries. No pyyaml dependency."""
    if not os.path.isfile(path):
        return []

    with open(path, encoding="utf-8") as f:
        content = f.read()

    # Split on top-level "- name:" pattern entries
    entries = []
    current = {}
    in_checklist = False
    checklist = {}

    for line in content.split("\n"):
        stripped = line.strip()

        # New pattern entry
        if stripped.startswith("- name:") or (stripped.startswith("- ") and "name:" in stripped):
            if current:
                if checklist:
                    current["checklist"] = checklist
                entries.append(current)
            current = {}
            checklist = {}
            in_checklist = False
            # Parse the name field
            val = stripped.split("name:", 1)[1].strip().strip('"').strip("'")
            current["name"] = val

        # Detect checklist section start
        elif stripped == "checklist:":
            in_checklist = True

        elif in_checklist and ":" in stripped:
            # Inside checklist section
            key, _, val = stripped.partition(":")
            checklist[key.strip()] = val.strip()

        elif ":" in stripped and current:
            # Regular field (outside checklist)
            key, _, val = stripped.partition(":")
            current[key.strip()] = val.strip()

        # Reset checklist context on non-indented line
        if in_checklist and not stripped and current:
            pass  # blank line inside section, keep context

    if current:
        if checklist:
            current["checklist"] = checklist
        entries.append(current)

    return entries


def _is_present(value):
    """Check if a value is considered 'present' (non-empty, non-placeholder)"""
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return len(value.strip()) > 0 and value.strip().lower() not in ("null", "none", "-", "")
    if isinstance(value, (list, dict)):
        return len(value) > 0
    return True


def validate_pattern(checklist_data):
    """Validate a pattern's checklist against level gates."""
    results = {}
    for section, level_req in SECTION_LEVELS.items():
        value = checklist_data.get(section)
        present = _is_present(value)
        results[section] = {
            "present": present,
            "level_required": level_req,
            "value_preview": str(value)[:80] if value else None,
        }

    # Determine achieved level
    l1_sections = [s for s, r in results.items() if r["level_required"] == "L1"]
    l2_sections = [s for s, r in results.items() if r["level_required"] == "L2"]
    l3_sections = [s for s, r in results.items() if r["level_required"] == "L3"]

    l1_ok = all(results[s]["present"] for s in l1_sections)
    l2_ok = all(results[s]["present"] for s in l2_sections)
    l3_ok = all(results[s]["present"] for s in l3_sections)

    achieved = "L0"
    if l3_ok and l2_ok and l1_ok:
        achieved = "L3"
    elif l2_ok and l1_ok:
        achieved = "L2"
    elif l1_ok:
        achieved = "L1"

    blocking_l2 = [s for s in l2_sections if not results[s]["present"]]
    blocking_l3 = [s for s in l3_sections if not results[s]["present"]]

    # Add any missing L1 sections as blocking for L1 too
    blocking_l1 = [s for s in l1_sections if not results[s]["present"]]

    return {
        "achieved_level": achieved,
        "checklist": results,
        "blocking_for_l1": blocking_l1,
        "blocking_for_l2": blocking_l2,
        "blocking_for_l3": blocking_l3,
    }


def validate_registry(registry_path, pattern_name=None):
    """Validate pattern(s) from the registry file."""
    entries = _parse_registry_simple(registry_path)
    if not entries:
        return {"error": "No patterns found in registry", "patterns": []}

    results = []
    for entry in entries:
        name = entry.get("name", "unknown")
        if pattern_name and name != pattern_name:
            continue

        # Extract checklist section if nested
        checklist = entry.get("checklist", {})
        # If no checklist key, use entire entry as checklist
        if not checklist:
            checklist = {k: v for k, v in entry.items() if k in SECTION_LEVELS}

        validation = validate_pattern(checklist)
        validation["pattern"] = name
        results.append(validation)

    return {"patterns": results}


def main():
    parser = argparse.ArgumentParser(description="Loop Checklist Validator")
    parser.add_argument("--pattern", help="Validate specific pattern")
    parser.add_argument("--registry", help="Override registry path")
    parser.add_argument("--checklist-json", help="Validate inline JSON checklist")
    parser.add_argument("--json", action="store_true", help="Machine-readable output")
    args = parser.parse_args()

    if args.checklist_json:
        try:
            data = json.loads(args.checklist_json)
        except json.JSONDecodeError:
            print("Invalid JSON checklist", file=sys.stderr)
            sys.exit(1)
        result = validate_pattern(data)
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return

    registry_path = args.registry or _detect_paths()
    result = validate_registry(registry_path, pattern_name=args.pattern)

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        for p in result.get("patterns", []):
            name = p.get("pattern", "?")
            level = p.get("achieved_level", "L0")
            print(f"\n{name}: {level}")
            for section, info in p.get("checklist", {}).items():
                status = "✓" if info["present"] else "✗"
                print(f"  {status} {section} (requires {info['level_required']})")
            if p.get("blocking_for_l1"):
                print(f"  Blockers for L1: {', '.join(p['blocking_for_l1'])}")
            if p.get("blocking_for_l2"):
                print(f"  Blockers for L2: {', '.join(p['blocking_for_l2'])}")
            if p.get("blocking_for_l3"):
                print(f"  Blockers for L3: {', '.join(p['blocking_for_l3'])}")


if __name__ == "__main__":
    main()
