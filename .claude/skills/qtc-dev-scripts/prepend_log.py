#!/usr/bin/env python3
"""Prepend a LIFECYCLE entry to docs/project/memory/pipeline-log.md (newest-first).

The automated audit trail of the dev pipeline — one line per pipeline event. Tags:
  BRAINSTORM | ARCHITECT | DECOMPOSE | EXECUTE | VERIFY | RALPH

This is breadcrumbs, not decisions. Real decisions (the *why* behind a choice)
go to decisions.md via prepend_decision.py. Keeping them apart is what stops the
decision record from drowning under hundreds of lifecycle lines.

The sanity-doctor reads this file for its EXECUTE/VERIFY pairing checks.

Uses an exclusive file lock so concurrent writers don't interleave.

Usage:
  python prepend_log.py "- YYYY-MM-DD [TAG] message"
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _util import locked_prepend

PIPELINE_LOG = Path(__file__).resolve().parents[3] / "docs/project/memory/pipeline-log.md"


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("Usage: prepend_log.py '- YYYY-MM-DD [TAG] message'")
    entry = sys.argv[1].strip()
    try:
        locked_prepend(PIPELINE_LOG, "# Pipeline Log", entry)
    except (ValueError, FileNotFoundError) as e:
        sys.exit(f"ERROR: {e}")
    print(f"OK: {entry}")


main()
