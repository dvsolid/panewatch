#!/usr/bin/env python3
"""Set the status field in a task or epic frontmatter.

Usage: python mark_status.py <file_path> <new_status>
Valid statuses: ready | in-progress | done | blocked-by-human
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _util import split_doc, join_doc, set_field, _VALID_STATUSES


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("Usage: mark_status.py <file_path> <new_status>")
    path = Path(sys.argv[1])
    new_status = sys.argv[2]
    if new_status not in _VALID_STATUSES:
        sys.exit(f"ERROR: invalid status '{new_status}'. Valid: {_VALID_STATUSES}")
    if not path.exists():
        sys.exit(f"ERROR: file not found: {path}")
    text = path.read_text()
    fm, body = split_doc(text)
    if not fm:
        sys.exit(f"ERROR: no frontmatter in {path}")
    old_status = next(
        (line.split(":", 1)[1].strip() for line in fm.splitlines() if line.startswith("status:")),
        "<unknown>",
    )
    fm = set_field(fm, "status", new_status)
    path.write_text(join_doc(fm, body))
    print(f"{path.name}: {old_status} → {new_status}")


main()
