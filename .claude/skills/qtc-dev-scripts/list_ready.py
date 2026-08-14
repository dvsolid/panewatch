#!/usr/bin/env python3
"""List tasks that are ready to execute (status=ready + all deps done).

Usage: python list_ready.py [EPIC-NNN]
Output: table of task ID, title, and how many tasks it directly unblocks.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _util import find_vault, read_all_tasks


def count_unlocked(task_id: str, tasks: dict) -> int:
    """Count tasks that list task_id in their depends_on."""
    return sum(1 for t in tasks.values() if task_id in t["depends_on"])


def main() -> None:
    epic_filter = sys.argv[1].upper() if len(sys.argv) > 1 else None
    vault = find_vault()
    tasks = read_all_tasks(vault)

    done_ids = {tid for tid, t in tasks.items() if t["status"] == "done"}

    ready = []
    for tid, t in tasks.items():
        if t["status"] != "ready":
            continue
        if epic_filter and epic_filter not in t["epic"]:
            continue
        if all(dep in done_ids for dep in t["depends_on"]):
            ready.append((tid, t))

    if not ready:
        print("No ready tasks with satisfied dependencies.")
        return

    ready.sort(key=lambda x: x[0])
    print(f"{'ID':<12} {'Unlocks':>7}  Title")
    print("-" * 60)
    for tid, t in ready:
        unlocks = count_unlocked(tid, tasks)
        print(f"{tid:<12} {unlocks:>7}  {t['title']}")


main()
