#!/usr/bin/env python3
"""SessionStart hook: read docs/project/memory/*.md, emit compact index as additionalContext.

Budget: ~1500 tokens, split into PER-SECTION caps so the glossary can't starve
the rest (a single global cap let ~45 glossary terms eat the whole budget):
  - glossary.md   -> all terms, one-line definitions truncated to 120 chars
  - decisions.md  -> recent real decisions (lines starting with "- ")
  - preferences.md -> full content (small file by design)
  - failure-patterns.md -> ## headings only
  - pipeline-log.md -> last few lifecycle entries (continuity)

Output is JSON on stdout per Claude Code hook contract:
  {"hookSpecificOutput": {"hookEventName": "SessionStart",
                          "additionalContext": "<text>"}}

Silent no-op if memory dir is absent.
"""
import json
import sys
from pathlib import Path


MEMORY_DIR = Path("docs/project/memory")
BUDGET_CHARS = 6500  # ~1600 tokens at 4 chars/token (sum of per-section caps + headers)


def truncate(text: str, limit: int) -> str:
    return text if len(text) <= limit else text[: limit - 3] + "..."


def read_glossary(path: Path) -> str:
    if not path.exists():
        return ""
    lines = []
    for raw in path.read_text().splitlines():
        if raw.startswith("## "):
            term = raw[3:].strip()
            lines.append(f"- **{term}**")
        elif raw.strip() and not raw.startswith("#") and lines:
            if lines[-1].endswith("**"):
                lines[-1] = f"{lines[-1]}: {truncate(raw.strip(), 120)}"
    return "\n".join(lines)


def read_log_lines(path: Path, n: int = 30) -> str:
    """First n entries (newest-first) from an append-only log file."""
    if not path.exists():
        return ""
    lines = [l for l in path.read_text().splitlines() if l.startswith("- ")]
    return "\n".join(lines[:n])


def read_failure_headings(path: Path) -> str:
    if not path.exists():
        return ""
    return "\n".join(l for l in path.read_text().splitlines() if l.startswith("## "))


def read_preferences(path: Path) -> str:
    return path.read_text() if path.exists() else ""


def build_index() -> str:
    # (heading, body, cap) — order = priority. Per-section caps keep the glossary
    # from starving decisions/preferences below it within BUDGET_CHARS.
    sections = [
        ("## Glossary (qtc-dev memory)", read_glossary(MEMORY_DIR / "glossary.md"), 2400),
        ("## Recent decisions", read_log_lines(MEMORY_DIR / "decisions.md"), 1800),
        ("## Workflow preferences", read_preferences(MEMORY_DIR / "preferences.md"), 1000),
        ("## Known failure patterns", read_failure_headings(MEMORY_DIR / "failure-patterns.md"), 600),
        ("## Recent pipeline activity", read_log_lines(MEMORY_DIR / "pipeline-log.md", n=6), 400),
    ]
    parts = [f"{h}\n{truncate(b.strip(), cap)}" for h, b, cap in sections if b.strip()]
    return truncate("\n\n".join(parts), BUDGET_CHARS)


def main() -> int:
    if not MEMORY_DIR.exists():
        return 0
    index = build_index()
    if not index.strip():
        return 0
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "SessionStart",
            "additionalContext": index,
        }
    }
    json.dump(payload, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
