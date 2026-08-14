"""Shared utilities for qtc-dev task scripts."""
import re
import sys
from pathlib import Path

_FRONTMATTER_RE = re.compile(r"^---\n(.*?)\n---\n", re.DOTALL)
_VALID_STATUSES = {"ready", "in-progress", "done", "blocked-by-human"}


def find_vault(start: Path | None = None) -> Path:
    """Walk up from start (default CWD) to find docs/project/."""
    p = (start or Path.cwd()).resolve()
    for candidate in [p, *p.parents]:
        vault = candidate / "docs" / "project"
        if vault.is_dir():
            return vault
    sys.exit("ERROR: docs/project/ not found — run from project root.")


def split_doc(text: str) -> tuple[str, str]:
    """Return (fm_text, body). fm_text is the raw YAML inside the --- fences."""
    m = _FRONTMATTER_RE.match(text)
    if not m:
        return "", text
    return m.group(1), text[m.end():]


def join_doc(fm_text: str, body: str) -> str:
    return f"---\n{fm_text}\n---\n{body}"


def locked_prepend(file_path: Path, header: str, entry: str) -> None:
    """Prepend `entry` immediately after the `header` line, under an exclusive lock.

    Shared by the append-only memory logs (decisions.md, pipeline-log.md) so
    concurrent writers don't interleave. `entry` must already start with '- '.
    Raises ValueError / FileNotFoundError on bad input.
    """
    import fcntl  # Unix-only; imported lazily so other _util users don't require it

    if not entry.startswith("- "):
        raise ValueError("entry must start with '- '")
    if not file_path.exists():
        # Auto-create with just the header so first write never fails (e.g. a vault
        # set up before pipeline-log.md existed). Idempotent for subsequent writes.
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_text(header + "\n")

    with file_path.open("r+") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        content = fh.read()
        idx = content.find(header)
        if idx == -1:
            raise ValueError(f"'{header}' header not found in {file_path}")
        insert_at = idx + len(header)
        if insert_at < len(content) and content[insert_at] == "\n":
            insert_at += 1
        new_content = content[:insert_at] + "\n" + entry + "\n" + content[insert_at:]
        fh.seek(0)
        fh.write(new_content)
        fh.truncate()


def get_field(fm_text: str, key: str) -> str:
    m = re.search(rf"^{re.escape(key)}:\s*(.+)$", fm_text, re.MULTILINE)
    return m.group(1).strip().strip('"') if m else ""


def set_field(fm_text: str, key: str, value: str) -> str:
    pattern = re.compile(rf"^({re.escape(key)}:\s*)(.+)$", re.MULTILINE)
    replacement = rf"\g<1>{value}"
    if pattern.search(fm_text):
        return pattern.sub(replacement, fm_text)
    return fm_text + f"\n{key}: {value}"


def get_depends_on(fm_text: str) -> list[str]:
    """Parse depends_on: ["TASK-NNN", ...] or ["[[TASK-NNN]]", ...] → plain IDs."""
    m = re.search(r"^depends_on:\s*(\[.*?\])$", fm_text, re.MULTILINE)
    if not m:
        return []
    raw = m.group(1)
    ids = re.findall(r"TASK-\d+", raw)
    return ids


def read_all_tasks(vault: Path) -> dict[str, dict]:
    """Return {task_id: {status, title, depends_on, path}} for all task files."""
    tasks: dict[str, dict] = {}
    for p in (vault / "tasks").glob("*.md"):
        text = p.read_text()
        fm, _ = split_doc(text)
        tid = get_field(fm, "id")
        if not tid:
            continue
        tasks[tid] = {
            "status": get_field(fm, "status"),
            "title": get_field(fm, "title"),
            "depends_on": get_depends_on(fm),
            "epic": get_field(fm, "epic"),
            "standalone": get_field(fm, "standalone") == "true",
            "path": p,
        }
    return tasks
