#!/usr/bin/env python3
"""Atomically allocate one counter ID from .counters.yml.

Usage: python allocate_id.py <epic|task|adr>
Prints: EPIC-006, TASK-037, ADR-011, etc.
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _util import find_vault


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1].lower() not in ("epic", "task", "adr"):
        sys.exit("Usage: allocate_id.py <epic|task|adr>")
    kind = sys.argv[1].lower()
    vault = find_vault()
    path = vault / "memory" / ".counters.yml"
    if not path.exists():
        sys.exit(f"ERROR: {path} not found")
    text = path.read_text()
    m = re.search(rf"^{kind}:\s*(\d+)$", text, re.MULTILINE)
    if not m:
        sys.exit(f"ERROR: key '{kind}' not found in {path}")
    new_val = int(m.group(1)) + 1
    path.write_text(text.replace(m.group(0), f"{kind}: {new_val}"))
    print(f"{kind.upper()}-{new_val:03d}")


main()
