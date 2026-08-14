#!/usr/bin/env python3
"""Append a review section to a task file and update status/review_failures.

Usage:
  python append_review.py gate    <file_path> "<command>"              # run test suite; print VERDICT; exit 0/1
  python append_review.py pass    <file_path> "<summary>" "<command>"  # mark done — REFUSED unless GREEN
  python append_review.py fail    <file_path> "<issue1>|<issue2>|..."
  python append_review.py blocked <file_path> "<reason>"               # escalate to human, no strike

`<command>` is any shell command whose exit code reflects test outcome (0 → GREEN,
non-zero → RED). Run from the repo root. The same command is passed to both `gate`
and `pass` so `pass` can re-run it as a mechanical guard.

`pass` reuses `gate`'s verdict instead of re-running the command when the working
tree (HEAD + uncommitted changes) is byte-identical to when `gate` last verified it
— see `_tree_signature`/`_cache_get`/`_cache_put` below. This does not weaken the
guard: `pass` still refuses on anything but an independently-subprocess-verified
GREEN for the exact command and exact tree state, it just avoids re-running a test
suite against code that provably hasn't changed since the last real run.
"""
import fcntl
import hashlib
import json
import os
import subprocess
import sys
import time
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from _util import split_doc, join_doc, get_field, set_field

REPO_ROOT = Path(__file__).resolve().parents[3]
_CACHE_PATH = REPO_ROOT / "docs" / "project" / ".cache" / "gate-cache.json"
_CACHE_LOCK_PATH = _CACHE_PATH.with_suffix(".lock")
_CACHE_TTL_SECONDS = 1800


def _last_line(out: str) -> str:
    lines = [ln.strip() for ln in out.splitlines() if ln.strip()]
    return lines[-1] if lines else "(no output)"


def _tree_signature() -> str:
    """Hash of HEAD + full working-tree diff + untracked file contents, so a
    cached verdict is only reused while the tree is unchanged since it was
    produced. `git diff HEAD` and `git status --porcelain` alone don't cover
    this: neither reflects the *content* of an untracked file, only that it
    exists — so untracked files are hashed individually here."""
    parts = []
    for cmd in ("git rev-parse HEAD", "git diff HEAD"):
        r = subprocess.run(cmd, cwd=REPO_ROOT, shell=True, capture_output=True, text=True)
        parts.append(r.stdout)
    untracked = subprocess.run(
        "git ls-files --others --exclude-standard -z",
        cwd=REPO_ROOT, shell=True, capture_output=True, text=True,
    ).stdout
    cache_dir = _CACHE_PATH.parent.resolve()
    for rel in filter(None, untracked.split("\0")):
        path = (REPO_ROOT / rel).resolve()
        if path.parent == cache_dir:
            continue  # the gate cache (and its lock/tmp files) must never feed its own signature
        parts.append(rel)
        try:
            parts.append(hashlib.sha256(path.read_bytes()).hexdigest())
        except OSError:
            parts.append("(unreadable)")
    return hashlib.sha256("".join(parts).encode()).hexdigest()


class _cache_lock:
    """Exclusive file lock serializing cache read-modify-write across
    processes, mirroring the single-writer `knowledge/.lock` convention used
    elsewhere in this project."""

    def __enter__(self):
        _CACHE_LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
        self._fh = open(_CACHE_LOCK_PATH, "w")
        fcntl.flock(self._fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc_info):
        fcntl.flock(self._fh, fcntl.LOCK_UN)
        self._fh.close()


def _cache_load() -> dict:
    if not _CACHE_PATH.exists():
        return {}
    try:
        return json.loads(_CACHE_PATH.read_text())
    except (json.JSONDecodeError, OSError):
        return {}


def _cache_write(cache: dict) -> None:
    """Write via temp-file + atomic rename so a concurrent reader never
    observes a half-written file."""
    _CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = _CACHE_PATH.with_suffix(f".tmp{os.getpid()}")
    tmp.write_text(json.dumps(cache, indent=2))
    tmp.replace(_CACHE_PATH)


def _cache_get(command: str, tree_sig: str) -> tuple[str, str] | None:
    entry = _cache_load().get(hashlib.sha256(command.encode()).hexdigest())
    if not entry or entry["tree_sig"] != tree_sig:
        return None
    if time.time() - entry["ts"] > _CACHE_TTL_SECONDS:
        return None
    return entry["verdict"], entry["detail"]


def _cache_put(command: str, tree_sig: str, verdict: str, detail: str) -> None:
    with _cache_lock():
        cache = _cache_load()
        cache[hashlib.sha256(command.encode()).hexdigest()] = {
            "tree_sig": tree_sig, "verdict": verdict, "detail": detail, "ts": time.time(),
        }
        _cache_write(cache)


def classify(command: str) -> tuple[str, str]:
    """Run command from repo root. Return (GREEN|RED, detail)."""
    try:
        r = subprocess.run(
            command, cwd=REPO_ROOT, shell=True,
            capture_output=True, text=True, timeout=600,
        )
    except subprocess.TimeoutExpired:
        return "RED", f"timed out after 600s"

    summary = _last_line(r.stdout + r.stderr)
    if r.returncode == 0:
        return "GREEN", summary
    return "RED", summary


def classify_cached(command: str) -> tuple[str, str, bool]:
    """classify(), but reuses a still-fresh cached verdict for this exact
    command and tree state instead of re-running it. Returns (verdict, detail,
    was_cached)."""
    tree_sig = _tree_signature()
    cached = _cache_get(command, tree_sig)
    if cached is not None:
        return cached[0], cached[1], True
    verdict, detail = classify(command)
    _cache_put(command, tree_sig, verdict, detail)
    return verdict, detail, False


def do_gate(command: str) -> None:
    verdict, detail, cached = classify_cached(command)
    tag = " (cached)" if cached else ""
    print(f"VERDICT: {verdict}{tag} — {detail}")
    sys.exit(0 if verdict == "GREEN" else 1)


def do_pass(path: Path, summary: str, command: str) -> None:
    verdict, detail, cached = classify_cached(command)
    if verdict != "GREEN":
        print(f"REFUSED: gate is {verdict} — {detail}")
        print("Cannot mark done. Route as `fail` or `blocked`; do not override.")
        sys.exit(1)
    fm, body = split_doc(path.read_text())
    fm = set_field(fm, "status", "done")
    tag = " (cached — tree unchanged since last gate)" if cached else ""
    section = (
        f"\n## Review\nPassed {date.today().isoformat()}. {summary}\n"
        f"Gate: GREEN{tag} ({detail}).\n"
    )
    path.write_text(join_doc(fm, body + section))
    print(f"PASS: {path.name} → done (gate verified GREEN)")


def do_fail(path: Path, payload: str) -> None:
    fm, body = split_doc(path.read_text())
    failures = int(get_field(fm, "review_failures") or "0") + 1
    fm = set_field(fm, "review_failures", str(failures))
    new_status = "blocked-by-human" if failures >= 2 else "ready"
    fm = set_field(fm, "status", new_status)
    lines = "\n".join(f"- {i.strip()}" for i in payload.split("|"))
    section = f"\n## Review notes (attempt {failures})\n{lines}\n"
    path.write_text(join_doc(fm, body + section))
    print(f"FAIL (attempt {failures}): {path.name} → {new_status}")
    if new_status == "blocked-by-human":
        print("  → Two failures: task is now blocked-by-human. Human intervention required.")


def do_blocked(path: Path, reason: str) -> None:
    fm, body = split_doc(path.read_text())
    fm = set_field(fm, "status", "blocked-by-human")
    safe = reason.replace("\\", "\\\\").replace("\n", " ").strip()
    fm = set_field(fm, "blocker_question", f'"{safe}"')
    section = f"\n## Blocked by human\n{reason.strip()}\n"
    path.write_text(join_doc(fm, body + section))
    print(f"BLOCKED: {path.name} → blocked-by-human (no strike consumed)")


def main() -> None:
    if len(sys.argv) < 3 or sys.argv[1] not in ("gate", "pass", "fail", "blocked"):
        sys.exit("Usage: append_review.py <gate|pass|fail|blocked> <file_path> [command|summary command|issues|reason]")

    outcome, path_str = sys.argv[1], sys.argv[2]
    path = Path(path_str)
    if not path.exists():
        sys.exit(f"ERROR: {path} not found")

    if outcome == "gate":
        if len(sys.argv) < 4:
            sys.exit("Usage: append_review.py gate <file_path> <command>")
        do_gate(sys.argv[3])
        return

    if len(sys.argv) < 4:
        sys.exit(f"Usage: append_review.py {outcome} <file_path> <text> [command]")

    if outcome == "pass":
        if len(sys.argv) < 5:
            sys.exit("Usage: append_review.py pass <file_path> <summary> <command>")
        do_pass(path, sys.argv[3], sys.argv[4])
    elif outcome == "fail":
        do_fail(path, sys.argv[3])
    else:
        do_blocked(path, sys.argv[3])


main()
