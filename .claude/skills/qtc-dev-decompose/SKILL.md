---
name: qtc-dev-decompose
description: Use when an architected feature spec needs to be broken into an epic and atomic tracer-bullet tasks. Produces one epic file and N task files in docs/project/, each task being a vertical slice through all layers. Verifies user approval on granularity before writing files.
---

# qtc-dev-decompose

Break an architected feature into an epic + atomic tracer-bullet tasks. One epic per feature; many tasks per epic.

## Glossary

- **Tracer bullet** — a thin vertical slice that cuts through every layer (schema, API, UI, tests) end-to-end. Demoable on its own.
- **Vertical slice** — same as tracer bullet. We use "slice" for the file body, "task" for the entity.
- **Test seam** — the public boundary at which the slice's behavior is tested.

See [VERTICAL-SLICES.md](VERTICAL-SLICES.md) for the discipline.

## When this runs

User invokes `/qtc-dev-decompose <feature-path>`. Feature spec must be at `status: architected`.

## Process

### 1. Read context

- Feature spec (full body, including the `## Architecture` section).
- `memory/glossary.md`.
- `memory/.counters.yml`.

If `status != architected`, abort with: "Run `/qtc-dev-architect` first."

### 2. Draft vertical slices

Per VERTICAL-SLICES.md: each slice must cut end-to-end and be demoable. Prefer many thin slices over few thick ones. Slices may have `depends_on` relationships but never circular.

For each slice:

- **Title** — imperative, short.
- **Slice description** — one paragraph, end-to-end behavior.
- **Acceptance** — bulleted observable behaviors (not implementation steps).
- **Test seam** — where the test will be written, tied back to an architect module.
- **Depends on** — list of sibling slice IDs that must complete first.

### 3. Quiz the user on granularity

Present the breakdown as a numbered list with title, dependencies, and a one-line slice summary. Ask:

- "Does the granularity feel right? (too coarse / too fine)"
- "Are the dependencies correct?"
- "Should any slices be merged or split?"

Iterate until the user approves.

### 4. Allocate IDs atomically

Run `python .claude/skills/qtc-dev-scripts/allocate_id.py epic` once, then `python .claude/skills/qtc-dev-scripts/allocate_id.py task` once per task slice. Each call increments the counter and prints the new ID (`EPIC-007`, `TASK-042`). Do not read/write `.counters.yml` by hand.

### 5. Write the epic file

`docs/project/epics/EPIC-NNN-{slug}.md`:

```markdown
---
id: EPIC-NNN
title: <epic title>
type: epic
status: ready
feature: "[[features/YYYY-MM-DD-{feature-slug}]]"
created: <YYYY-MM-DD>
---

# <Epic title>

## Goal
<one sentence — the user-visible outcome>

## Tasks
- [[TASK-NNN-{slug}|TASK-NNN]] — <task title>
- [[TASK-NNN+1-{slug}|TASK-NNN+1]] — <task title>

## Notes
<optional pointers to ADRs, architect modules>
```

### 6. Write each task file

`docs/project/tasks/TASK-NNN-{slug}.md`:

```markdown
---
id: TASK-NNN
title: <task title>
type: task
status: ready
epic: "[[epics/EPIC-NNN-{slug}]]"
depends_on: ["TASK-NNN-2"]
created: <YYYY-MM-DD>
blocker_question: ""
review_failures: 0
claimed_at: ""
claimed_by: ""
---

# <Task title>

## Slice
<one paragraph — end-to-end behavior>

## Acceptance
- [ ] Behavior 1 observable through the public interface
- [ ] Behavior 2 ...

## Test seam
<seam description; link to architect module>

## Notes
<optional>
```

### 7. Update feature spec

Open the feature spec. Flip frontmatter `status: architected` → `status: decomposed`. Populate `epics: ["[[epics/EPIC-NNN-{slug}]]"]`.

### 8. Append one-line pipeline-log entry

Run (lifecycle breadcrumb → `pipeline-log.md`, not a decision):

```bash
python3 .claude/skills/qtc-dev-scripts/prepend_log.py \
  "- YYYY-MM-DD [DECOMPOSE] <feature-slug>: EPIC-NNN with N tasks"
```

### 9. Report

Tell the user: "Epic EPIC-NNN with N tasks created. Run `/qtc-dev-ralph EPIC-NNN` to start the autonomous loop, or `/qtc-dev-execute-task TASK-NNN` to drive one task manually."

## Discipline

- **Vertical, not horizontal.** Every task cuts through all layers.
- **Acceptance describes behavior**, not implementation.
- **Many thin slices > few thick ones.** A slice should be ~½ day of work for a focused engineer.
- **Granularity is collaborative.** Always quiz the user before writing files.
- **ID allocation is atomic.** Read-write the counter under one operation; don't allocate halfway and abort.
