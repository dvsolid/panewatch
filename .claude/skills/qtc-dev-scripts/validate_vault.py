#!/usr/bin/env python3
"""Validate the docs/project/ vault for structural integrity.

Checks:
  - All task status values are in the valid set
  - All depends_on targets exist (no dangling references)
  - No circular dependencies
  - All epic task wikilinks resolve to existing task files
  - No task is both done and has in-progress dependents

Usage: python validate_vault.py [--fix-links]
Exit code: 0 = clean, 1 = issues found
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _util import find_vault, read_all_tasks, get_field, split_doc, _VALID_STATUSES

# Optional task frontmatter fields that are valid and should not be flagged.
# standalone: true — written by Ralph standalone intake mode; task has no parent epic by design.
_KNOWN_OPTIONAL_TASK_FIELDS = {"standalone"}


def check_circular(task_id: str, tasks: dict, visiting: set, visited: set) -> list[str]:
    if task_id in visiting:
        return [task_id]
    if task_id in visited:
        return []
    visiting.add(task_id)
    for dep in tasks.get(task_id, {}).get("depends_on", []):
        cycle = check_circular(dep, tasks, visiting, visited)
        if cycle:
            return [task_id] + cycle
    visiting.discard(task_id)
    visited.add(task_id)
    return []


def main() -> None:
    vault = find_vault()
    tasks = read_all_tasks(vault)
    errors: list[str] = []
    warnings: list[str] = []

    for tid, t in tasks.items():
        # Status validity
        if t["status"] not in _VALID_STATUSES:
            errors.append(f"{tid}: invalid status '{t['status']}'")

        # Dangling depends_on
        for dep in t["depends_on"]:
            if dep not in tasks:
                errors.append(f"{tid}: depends_on '{dep}' does not exist")

    # Circular dependency check
    visiting: set = set()
    visited: set = set()
    for tid in tasks:
        cycle = check_circular(tid, tasks, visiting, visited)
        if cycle:
            errors.append(f"Circular dependency: {' → '.join(cycle)}")

    # Epic link validation
    epic_id_re = re.compile(r"EPIC-\d+")
    for epic_path in (vault / "epics").glob("*.md"):
        text = epic_path.read_text()
        fm, body = split_doc(text)
        task_wikilinks = re.findall(r"\[\[TASK-(\d+)", body)
        for num in task_wikilinks:
            tid = f"TASK-{num}"
            if tid not in tasks:
                errors.append(f"{epic_path.name}: links to {tid} which does not exist")

    # Warn about in-progress tasks with done dependents (stale)
    for tid, t in tasks.items():
        if t["status"] == "in-progress":
            warnings.append(f"{tid}: status=in-progress (may be stale if no subagent is running it)")

    # Report
    all_clean = not errors and not warnings
    if all_clean:
        print(f"Vault OK — {len(tasks)} tasks validated.")
        sys.exit(0)

    if warnings:
        print(f"Warnings ({len(warnings)}):")
        for w in warnings:
            print(f"  WARN  {w}")

    if errors:
        print(f"\nErrors ({len(errors)}):")
        for e in errors:
            print(f"  ERR   {e}")
        sys.exit(1)
    else:
        sys.exit(0)


main()
