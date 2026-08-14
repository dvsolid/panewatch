#!/usr/bin/env python3
"""Convert wikilink task IDs in frontmatter depends_on to plain IDs.

Transforms: depends_on: ["[[TASK-018]]"]
        to: depends_on: ["TASK-018"]

Leaves Obsidian wikilinks in the document body untouched.
Idempotent — safe to re-run.

Usage: python normalize_links.py [--dry-run]
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _util import find_vault, split_doc, join_doc

_WIKILINK_ID_RE = re.compile(r'"\[\[(?:[^\]|]*?/)?(TASK-\d+)[^\]]*?\]\]"')


def normalize_depends_on(fm_text: str) -> tuple[str, bool]:
    """Return (new_fm_text, changed)."""
    def replace_match(m: re.Match) -> str:
        return f'"{m.group(1)}"'

    new_fm = re.sub(
        r"^(depends_on:\s*)(\[.*?\])$",
        lambda m: m.group(1) + _WIKILINK_ID_RE.sub(replace_match, m.group(2)),
        fm_text,
        flags=re.MULTILINE,
    )
    return new_fm, new_fm != fm_text


def main() -> None:
    dry_run = "--dry-run" in sys.argv
    vault = find_vault()
    changed_files = []

    for path in (vault / "tasks").glob("*.md"):
        text = path.read_text()
        fm, body = split_doc(text)
        if not fm:
            continue
        new_fm, changed = normalize_depends_on(fm)
        if changed:
            if not dry_run:
                path.write_text(join_doc(new_fm, body))
            changed_files.append(path.name)

    if changed_files:
        verb = "Would update" if dry_run else "Updated"
        print(f"{verb} {len(changed_files)} file(s):")
        for f in sorted(changed_files):
            print(f"  {f}")
    else:
        print("All depends_on links already normalized.")


main()
