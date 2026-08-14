---
name: qtc-dev-sanity-doctor
description: "Use when you want to audit the docs/project/ vault for health issues: cross-reference breaks, status inconsistencies, semantic drift, and coverage gaps. Applies safe in-place fixes and prints a severity-bucketed report."
---

# qtc-dev-sanity-doctor

Vault health check. Three phases: **map → analyze → fix + report**.

---

## Setup

```bash
DOCTOR=".claude/skills/qtc-dev-sanity-doctor/doctor.py"
VAULT="docs/project"
```

---

## Valid optional task fields

The following optional frontmatter fields are valid on task files and must not be treated as errors:

- `standalone: true` — present on tasks created by Ralph's standalone intake mode. These tasks have no parent epic (`epic:` is empty) and no `depends_on` by design. Orphan-task checks (check #18) must skip them.

---

## Phase 1: Build vault map

```bash
python $DOCTOR map > /tmp/vault_map.json
```

Read `/tmp/vault_map.json`. Structure:

```
tasks:    {TASK-NNN: {status, parent_epic, depends_on[], acceptance_text, standalone, file}}
epics:    {EPIC-NNN: {status, tasks[], feature_slug, file}}
features: {slug: {status, epic_ids[], file}}
adrs:     {NNN: {id, slug, status, supersedes, superseded_by, file}}
glossary_terms: [str]
decisions: [{line, text, ids[]}]
failure_pattern_module_refs: [str]
root_use_cases_text: str
```

Count each artifact type for the report header.

---

## Phase 2: Run checks

Accumulate findings into three lists: `errors`, `warnings`, `info`.

Format each finding as: `[tag]  file:line — description`

### 🔴 Cross-reference integrity → errors

For each check, record the finding with tag `[xref]` and the source file.

1. **Task depends_on**: for each task, check every ID in `depends_on[]` exists in `tasks`.
2. **Epic task list**: for each epic, check every ID in `tasks[]` exists in `tasks`.
3. **Epic → feature link**: for each epic where `feature_slug` is non-empty, check it exists in `features`.
4. **ADR supersedes**: for each ADR where `supersedes` is non-empty, extract the numeric ID and check it exists in `adrs`.
5. **Stale log refs**: for each entry in `decisions` (which now spans both `decisions.md` and `pipeline-log.md` — see each entry's `file`), check every ID in `ids[]` exists in `tasks` or `epics`. Collect stale IDs **grouped by `file`** for Phase 3 autofix.
6. **Task parent_epic**: for each task where `parent_epic` is non-empty, check it exists in `epics`.

### 🟡 Status consistency → warnings

7. **Epic done but tasks open**: for each epic with `status: done`, check all its `tasks[]` have `status: done`. Tag: `[status]`.
8. **In-progress without EXECUTE**: for each task with `status: in-progress`, check a `[EXECUTE]` entry exists in `pipeline-log.md` containing that task ID. Tag: `[status]`.
9. **EXECUTE without VERIFY**: for each task ID that appears in a `[EXECUTE]` entry in `pipeline-log.md`, check a `[VERIFY]` entry for the same ID exists. Tag: `[status]`.
10. **Done without VERIFY**: for each task with `status: done`, check a `[VERIFY] TASK-NNN passed` entry exists in `pipeline-log.md`. Tag: `[status]`.
11. **Git-doc sync**: for each task with `status: done`, run:
    ```bash
    python $DOCTOR git-check TASK-NNN
    ```
    If `found: false`, add warning: `[git]  tasks/TASK-NNN-*.md — status=done but no commit contains "TASK-NNN"`.

### 🟡 Semantic drift → warnings

12. **Undefined terms in docs**: scan all docs under `$VAULT` for `**term**` and `` `TermName` `` patterns that start with an uppercase letter. For each unique term not in `glossary_terms`, add: `[drift]  file — "TermName" used but not in glossary`. Skip terms that look like code (all-caps, snake_case, file paths).
13. **Dead glossary terms**: for each glossary term, count its occurrences across all docs excluding `memory/glossary.md`. If 0: `[drift]  memory/glossary.md — "Term" defined but never referenced`.
14. **Module names in docs without code file**: extract type names matching `[A-Z][a-zA-Z]+(Client|Parser|Pipeline|Poller|Comparator|Engine|Matcher|Resolver|Service|Source|Detector)` from all docs. For each, check if a Swift file matching `<TypeName>.swift` exists under `Sources/`. If not found: `[drift]  file — "TypeName" mentioned but not found in Sources/`.
15. **Failure pattern module drift**: for each name in `failure_pattern_module_refs`, apply the same lookup against `Sources/`. If not found, add to stale modules list for Phase 3 autofix and add: `[drift]  memory/failure-patterns.md — "TypeName" referenced but not in Sources/`.

### 🟢 Coverage gaps → info

16. **Feature without epic**: for each feature with `epic_ids[]` empty or missing: `[coverage]  features/slug.md — no linked epic`.
17. **Epic without tasks**: for each epic with empty `tasks[]`: `[coverage]  epics/EPIC-NNN-*.md — no tasks listed`.
18. **Orphan tasks**: for each task whose `parent_epic` is not referenced by any epic's `tasks[]`, **and whose `standalone` field is not `true`**: `[coverage]  tasks/TASK-NNN-*.md — not referenced by any epic`. Standalone tasks (`standalone: true`) have no parent epic by design — skip them here.
19. **Uncovered use cases**: extract `## Heading` lines from `root_use_cases_text`. For each heading, check if the heading text appears in any task or epic file body. If not: `[coverage]  000-base-use-cases.md — "Heading" not mentioned in any task or epic`.
20. **Duplicate tasks**: run:
    ```bash
    python $DOCTOR similarity-all
    ```
    For each pair in `similar_pairs`: `[dup]  TASK-A × TASK-B — acceptance criteria N% similar`.

---

## Phase 3: Apply fixes and report

### Auto-fixes

Collect stale_ids from check #5 (grouped by source file), stale_modules from check #15.

For each memory log that has stale refs, run autofix on that file (it marks the stale lines with `[STALE]`):
```bash
python $DOCTOR autofix decisions $VAULT/memory/decisions.md    --stale-ids TASK-X ...
python $DOCTOR autofix decisions $VAULT/memory/pipeline-log.md --stale-ids TASK-Y ...
```

If stale_modules is non-empty:
```bash
python $DOCTOR autofix failure-patterns $VAULT/memory/failure-patterns.md --stale-modules ModA ModB ...
```

Record each auto-fix applied (file + line + description).

### Propose fixes (AskUserQuestion)

For any glossary term casing inconsistency (check #12 found a term that matches a glossary term
when lowercased): show the before/after lines via AskUserQuestion (yes/no). If approved, apply the
edit. If declined, move the finding to warnings instead.

### Print report

```
=== qtc-dev-sanity-doctor ===
Vault: N tasks · N epics · N features · N ADRs

🔴 ERRORS (N)
  [tag]    file:line — description
  ...

🟡 WARNINGS (N)
  [tag]    file:line — description
  ...

🟢 INFO (N)
  [tag]    file:line — description
  ...

Auto-fixed (N):
  file:line — description
```

Suppress sections with zero findings. Print `All clear.` if all three lists are empty.
