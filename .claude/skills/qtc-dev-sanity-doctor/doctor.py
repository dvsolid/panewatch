#!/usr/bin/env python3
"""qtc-dev-sanity-doctor helper — vault map, git check, similarity, autofix."""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

VAULT = Path("docs/project")


# ── frontmatter helpers ──────────────────────────────────────────────────────

def _parse_frontmatter(text: str) -> dict:
    """Extract key: value pairs from YAML frontmatter (no external deps)."""
    if not text.startswith("---"):
        return {}
    try:
        end = text.index("---", 3)
    except ValueError:
        return {}
    fm: dict = {}
    for line in text[3:end].splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            continue
        key, _, val = line.partition(":")
        val = val.strip()
        # Handle quoted strings first: "..." or '...'
        if (val.startswith('"') and val.endswith('"')) or (val.startswith("'") and val.endswith("'")):
            fm[key.strip()] = val[1:-1]
        # Handle list values: ["a", "b"] or [a, b]
        elif val.startswith("[") and val.endswith("]"):
            inner = val[1:-1]
            items = [i.strip().strip('"').strip("'") for i in inner.split(",") if i.strip()]
            fm[key.strip()] = items
        else:
            fm[key.strip()] = val.strip()
    return fm


def _extract_epic_id(link: str) -> str | None:
    """'[[epics/EPIC-004-slug]]' → 'EPIC-004'"""
    m = re.search(r'EPIC-(\d+)', link)
    return f"EPIC-{m.group(1)}" if m else None


def _extract_task_id(link: str) -> str | None:
    """'[[TASK-021]]' or 'TASK-021' → 'TASK-021'"""
    m = re.search(r'TASK-(\d+)', link)
    return f"TASK-{m.group(1)}" if m else None


def _extract_feature_slug(link: str) -> str | None:
    """'[[features/2026-05-12-slug]]' → '2026-05-12-slug'"""
    m = re.search(r'features/(\d{4}-\d{2}-\d{2}-[^\]"\']+)', link)
    return m.group(1) if m else None


# ── map command ──────────────────────────────────────────────────────────────

def cmd_map():
    tasks = {}
    tasks_dir = VAULT / "tasks"
    if tasks_dir.exists():
        for f in sorted(tasks_dir.glob("TASK-*.md")):
            text = f.read_text()
            fm = _parse_frontmatter(text)
            task_id = fm.get("id", "")
            if not task_id:
                continue
            parent_epic = _extract_epic_id(fm.get("epic", ""))
            depends_on_raw = fm.get("depends_on", [])
            if isinstance(depends_on_raw, str):
                depends_on_raw = [depends_on_raw] if depends_on_raw else []
            depends_on = [_extract_task_id(d) for d in depends_on_raw if _extract_task_id(d)]
            acc_m = re.search(r"## Acceptance\n(.*?)(?=\n## |\Z)", text, re.DOTALL)
            acceptance_text = acc_m.group(1).strip() if acc_m else ""
            tasks[task_id] = {
                "status": fm.get("status", ""),
                "parent_epic": parent_epic,
                "depends_on": depends_on,
                "acceptance_text": acceptance_text,
                "standalone": fm.get("standalone", "") == "true",
                "file": str(f.relative_to(VAULT)),
            }

    epics = {}
    epics_dir = VAULT / "epics"
    if epics_dir.exists():
        for f in sorted(epics_dir.glob("EPIC-*.md")):
            text = f.read_text()
            fm = _parse_frontmatter(text)
            epic_id = fm.get("id", "")
            if not epic_id:
                continue
            feature_slug = _extract_feature_slug(fm.get("feature", ""))
            task_ids = [f"TASK-{n}" for n in re.findall(r"\[\[TASK-(\d+)", text)]
            epics[epic_id] = {
                "status": fm.get("status", ""),
                "feature_slug": feature_slug,
                "tasks": task_ids,
                "file": str(f.relative_to(VAULT)),
            }

    features = {}
    features_dir = VAULT / "features"
    if features_dir.exists():
        for f in sorted(features_dir.glob("*.md")):
            text = f.read_text()
            fm = _parse_frontmatter(text)
            slug = f.stem
            epic_links = fm.get("epics", [])
            if isinstance(epic_links, str):
                epic_links = [epic_links]
            epic_ids = [_extract_epic_id(l) for l in epic_links if _extract_epic_id(l)]
            features[slug] = {
                "status": fm.get("status", ""),
                "epic_ids": epic_ids,
                "file": str(f.relative_to(VAULT)),
            }

    adrs = {}
    adr_dir = VAULT / "adr"
    if adr_dir.exists():
        for f in sorted(adr_dir.glob("*.md")):
            text = f.read_text()
            fm = _parse_frontmatter(text)
            num_m = re.match(r"^(\d+)", f.stem)
            num_id = num_m.group(1) if num_m else f.stem
            adrs[num_id] = {
                "id": fm.get("id", f.stem),
                "slug": f.stem,
                "status": fm.get("status", ""),
                "supersedes": fm.get("supersedes", ""),
                "superseded_by": fm.get("superseded_by", ""),
                "file": str(f.relative_to(VAULT)),
            }

    glossary_file = VAULT / "memory" / "glossary.md"
    glossary_terms = []
    if glossary_file.exists():
        glossary_terms = re.findall(r"^## (.+)$", glossary_file.read_text(), re.MULTILINE)

    # ID-bearing lines from both memory logs. decisions.md holds real decisions;
    # pipeline-log.md holds lifecycle breadcrumbs (EXECUTE/VERIFY/... — what rules
    # 8/9/10 match). Each entry carries its source file so autofix targets the right one.
    decisions = []
    for fname in ("decisions.md", "pipeline-log.md"):
        f = VAULT / "memory" / fname
        if not f.exists():
            continue
        for i, line in enumerate(f.read_text().splitlines(), 1):
            ids_found = re.findall(r"(TASK-\d+|EPIC-\d+)", line)
            if ids_found:
                decisions.append({"file": fname, "line": i, "text": line.strip(), "ids": ids_found})

    fp_file = VAULT / "memory" / "failure-patterns.md"
    fp_module_refs = []
    if fp_file.exists():
        fp_text = fp_file.read_text()
        fp_module_refs = re.findall(
            r"`([A-Z][a-zA-Z]+"
            r"(?:Client|Parser|Pipeline|Poller|Comparator|Engine|Matcher|Resolver|Service|Hook))`",
            fp_text,
        )

    use_cases_file = VAULT / "000-base-use-cases.md"
    root_use_cases_text = use_cases_file.read_text() if use_cases_file.exists() else ""

    print(json.dumps({
        "tasks": tasks,
        "epics": epics,
        "features": features,
        "adrs": adrs,
        "glossary_terms": glossary_terms,
        "decisions": decisions,
        "failure_pattern_module_refs": fp_module_refs,
        "root_use_cases_text": root_use_cases_text,
    }, indent=2))


# ── git-check command ────────────────────────────────────────────────────────

def cmd_git_check(task_id: str):
    result = subprocess.run(
        ["git", "log", "--oneline", "--all", f"--grep={task_id}"],
        capture_output=True, text=True,
    )
    lines = [l.strip() for l in result.stdout.splitlines() if l.strip()]
    print(json.dumps({"found": bool(lines), "commits": lines}))


# ── similarity-all command ───────────────────────────────────────────────────

def _jaccard(text_a: str, text_b: str) -> float:
    def tokens(t: str) -> set[str]:
        return set(re.findall(r"\b\w+\b", t.lower()))
    a, b = tokens(text_a), tokens(text_b)
    if not a and not b:
        return 0.0
    return len(a & b) / len(a | b)


def cmd_similarity_all():
    vault_map_result = subprocess.run(
        [sys.executable, __file__, "map"],
        capture_output=True, text=True,
    )
    if vault_map_result.returncode != 0:
        print(json.dumps({"error": vault_map_result.stderr, "similar_pairs": []}))
        return
    data = json.loads(vault_map_result.stdout)
    tasks = data["tasks"]
    eligible = [(tid, t["acceptance_text"]) for tid, t in tasks.items()
                if len(t.get("acceptance_text", "")) > 50]
    similar_pairs = []
    for i in range(len(eligible)):
        for j in range(i + 1, len(eligible)):
            tid_a, text_a = eligible[i]
            tid_b, text_b = eligible[j]
            score = _jaccard(text_a, text_b)
            if score >= 0.75:
                similar_pairs.append({"task_a": tid_a, "task_b": tid_b, "score": round(score, 3)})
    print(json.dumps({"similar_pairs": similar_pairs}))


# ── autofix command ──────────────────────────────────────────────────────────

def cmd_autofix(subtype: str, filepath: str, stale_ids: list[str], stale_modules: list[str]):
    path = Path(filepath)
    lines = path.read_text().splitlines(keepends=True)
    fixed = 0

    if subtype == "decisions":
        new_lines = []
        for line in lines:
            if any(sid in line for sid in stale_ids) and "[STALE]" not in line:
                line = line.rstrip("\n") + " [STALE]\n"
                fixed += 1
            new_lines.append(line)
        path.write_text("".join(new_lines))

    elif subtype == "failure-patterns":
        new_lines = []
        for line in lines:
            if any(f"`{m}`" in line for m in stale_modules) and "[STALE]" not in line:
                line = line.rstrip("\n") + " [STALE]\n"
                fixed += 1
            new_lines.append(line)
        path.write_text("".join(new_lines))

    print(json.dumps({"fixed": fixed}))


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="sanity-doctor helper")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("map")
    p_git = sub.add_parser("git-check")
    p_git.add_argument("task_id")
    sub.add_parser("similarity-all")
    p_fix = sub.add_parser("autofix")
    p_fix.add_argument("subtype", choices=["decisions", "failure-patterns"])
    p_fix.add_argument("filepath")
    p_fix.add_argument("--stale-ids", nargs="*", default=[])
    p_fix.add_argument("--stale-modules", nargs="*", default=[])
    args = parser.parse_args()
    if args.cmd == "map":
        cmd_map()
    elif args.cmd == "git-check":
        cmd_git_check(args.task_id)
    elif args.cmd == "similarity-all":
        cmd_similarity_all()
    elif args.cmd == "autofix":
        cmd_autofix(args.subtype, args.filepath, args.stale_ids, args.stale_modules)


if __name__ == "__main__":
    main()
