---
name: qtc-dev-architect
description: Use when a feature spec (in docs/project/features/) needs architectural sketching before decomposition. Identifies deep modules using the deletion test, sketches interfaces, captures ADRs for hard-to-reverse design choices, and updates the glossary inline. Output is appended to the feature spec.
---

# qtc-dev-architect

Sketch the architecture for a feature spec. Find deep modules; reject shallow ones. Capture interfaces. Surface ADRs.

## Glossary (architecture vocabulary — use these terms exactly)

- **Module** — anything with an interface and an implementation (function, class, package, slice).
- **Interface** — everything a caller must know to use the module: types, invariants, error modes, ordering, config.
- **Implementation** — the code inside.
- **Depth** — leverage at the interface: lots of behavior behind a small interface. **Deep** = high leverage. **Shallow** = interface nearly as complex as the implementation.
- **Seam** — where an interface lives; a place behavior can be altered without editing in place.
- **Adapter** — a concrete thing satisfying an interface at a seam.
- **Deletion test** — imagine deleting the module. If complexity vanishes, it was a pass-through; reject it. If complexity reappears across N callers, it earns its keep.

See [DEEP-MODULES.md](DEEP-MODULES.md) and [INTERFACE-DESIGN.md](INTERFACE-DESIGN.md) for the long-form discipline.

## When this runs

User invokes `/qtc-dev-architect <feature-path>` where `<feature-path>` is a feature spec written by qtc-dev-brainstorm.

## Process

### 1. Read context

- The feature spec (full body).
- `docs/project/memory/glossary.md`.
- `docs/project/adr/*.md` titles and statuses (don't re-litigate accepted ADRs).
- Existing code in the project that relates to the feature's domain (use `Agent` with `subagent_type=Explore` and `model="haiku"` for breadth).

### 2. Sketch candidate modules

Propose 3–7 modules. For each:

- **Name** (use glossary vocabulary).
- **Purpose** — one sentence.
- **Interface** — public functions/methods with type sketches; invariants; error modes. Sketch, not final.
- **Why deep** — apply the deletion test. Show what complexity would reappear across callers if this module didn't exist.

If a candidate fails the deletion test, drop it. Don't propose shallow modules for the sake of symmetry.

### 3. Present to user, iterate

Show the numbered candidate list. Ask:

- "Do these match your mental model?"
- "Which look shallow — anything that's just a pass-through?"
- "Anything missing?"

Iterate until the user confirms.

### 4. Capture ADRs

For each decision that passes the 3-of-3 test (hard to reverse, surprising, real trade-off), draft an ADR:

```markdown
---
id: ADR-NNNN
title: <decision>
status: proposed
date: <YYYY-MM-DD>
supersedes: ""
superseded_by: ""
tags: []
---

## Context
## Decision
## Consequences
## Alternatives considered
```

Increment `adr` in `memory/.counters.yml` atomically (read-write).

### 5. Update glossary

Any new module name that names a domain concept should land in `memory/glossary.md`. Append inline as the concept crystallizes.

### 6. Append architecture section to the feature spec

Edit the feature spec file: append after `## Further notes`:

```markdown
## Architecture

### Modules

#### <ModuleName>
- **Purpose**: ...
- **Interface**:
  ```
  <type-sketch or pseudocode>
  ```
- **Why deep**: <deletion-test reasoning>
- **Adapters at seam**: <if any — e.g., HTTP, local file, mock>

### ADRs introduced
- [[adr/0007-polling-not-webhooks]]
- ...
```

Flip frontmatter `status: drafted` → `status: architected`.

### 7. Record the pipeline-log entry, then the ADRs

First the lifecycle breadcrumb (→ `pipeline-log.md`):

```bash
python3 .claude/skills/qtc-dev-scripts/prepend_log.py \
  "- YYYY-MM-DD [ARCHITECT] <feature-slug>: N modules sketched, M ADRs proposed"
```

Then **record each ADR as a real decision** (→ `decisions.md`) — this is the point where load-bearing, hard-to-reverse choices crystallize, and the decision record is only useful if they land in it. One line per ADR, capturing the choice and what it rejects:

```bash
python3 .claude/skills/qtc-dev-scripts/prepend_decision.py \
  "- YYYY-MM-DD [ADR] NNN <slug> — <decision in one line>. Rejected: <alternatives>."
```

### 8. Report

Tell the user: "Architecture sketch appended to <feature-path>. ADRs at proposed status — review and accept. Run `/qtc-dev-decompose <feature-path>` to break into tasks."

## Discipline

- **Don't propose shallow modules.** Apply the deletion test ruthlessly.
- **Interfaces, not implementations.** Sketch shape and invariants; not internals.
- **Glossary first.** If you reach for a synonym, stop and check the glossary.
- **ADRs are rare.** All three of the 3-of-3 test must hold.
