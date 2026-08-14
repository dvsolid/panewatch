#!/usr/bin/env python3
"""Prepend a DECISION entry to docs/project/memory/decisions.md (newest-first).

For real decisions only — choices a future reader needs the *why* for. Tags:
  ADR | REQ CHANGE | EXPERIMENT | SPIKE | BUG FIX | INFRA | INTEGRATION

Automated lifecycle breadcrumbs (BRAINSTORM/ARCHITECT/DECOMPOSE/EXECUTE/VERIFY/
RALPH) are NOT decisions — write them to pipeline-log.md via prepend_log.py.

Uses an exclusive file lock so concurrent writers don't interleave.

Usage:
  python prepend_decision.py "- YYYY-MM-DD [TAG] message"
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _util import locked_prepend

DECISIONS = Path(__file__).resolve().parents[3] / "docs/project/memory/decisions.md"


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("Usage: prepend_decision.py '- YYYY-MM-DD [TAG] message'")
    entry = sys.argv[1].strip()
    try:
        locked_prepend(DECISIONS, "# Decisions", entry)
    except (ValueError, FileNotFoundError) as e:
        sys.exit(f"ERROR: {e}")
    print(f"OK: {entry}")


main()
