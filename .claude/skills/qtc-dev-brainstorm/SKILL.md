---
name: qtc-dev-brainstorm
description: Use when capturing a new feature idea for this project. Interrogates the user one question at a time, produces a structured feature spec in docs/project/features/, updates the glossary inline, and proposes ADRs only when a load-bearing alternative is rejected. Replaces ad-hoc PRDs.
---

# qtc-dev-brainstorm

Turn a raw idea into a structured feature spec through disciplined interrogation. Use glossary terms exactly; sharpen fuzzy language inline.

## When this runs

User invokes `/qtc-dev-brainstorm <optional one-liner>`. The skill drives the interview; the user answers.

## Glossary

- **Feature spec** — the markdown file produced by this skill, saved to `docs/project/features/YYYY-MM-DD-{slug}.md`.
- **Slug** — kebab-case identifier derived from the feature title.
- **Load-bearing alternative** — a rejected option whose rejection would surprise a future reader; only these become ADRs (Matt Pocock 3-of-3 test).

## Process

### 1. Read prior memory

Before the first question:

- Read `docs/project/memory/glossary.md` so questions use the project's vocabulary.
- Read existing `docs/project/features/*.md` titles so you don't propose an overlapping feature.
- Read recent decisions in `docs/project/memory/decisions.md`.

### 2. Interview the user — one question at a time

Walk the design tree. For each question:

- State your recommended answer with reasoning.
- Prefer multiple-choice ≥ open-ended where the space is small.
- Wait for the answer before the next question. Never batch.

Cover at minimum:

1. **Problem from the user's perspective** — who hurts, what hurts, why now.
2. **Solution from the user's perspective** — the observable outcome.
3. **Boundaries** — what's in scope, what's deliberately out.
4. **Vocabulary check** — for every domain term used, confirm it matches the glossary or propose adding/sharpening it. If a term conflicts with the glossary, call it out: "Glossary defines X as Y; you seem to mean Z — which is it?"
5. **Major user stories** — long numbered list, format `As an <actor>, I want <feature>, so that <benefit>`.
6. **Hard constraints** — performance, security, integration, compliance.
7. **Risks & open questions** — what would force a re-plan.

### 3. Glossary upkeep — inline

When a new term crystallizes, append it to `docs/project/memory/glossary.md` immediately. Don't batch. Format:

```markdown
## TermName
One-line definition. Optional second sentence for nuance.
```

If you sharpen an existing term, edit it in place — keep the heading stable so wikilinks survive.

### 4. ADR offer — sparingly

Only offer an ADR when **all three** are true:

1. Hard to reverse.
2. Surprising without context.
3. The user rejected a real alternative for a specific reason.

Frame it: "Want me to record this as an ADR so future architecture reviews don't re-suggest it?" If yes, write the ADR under `docs/project/adr/NNNN-{slug}.md` (increment counter), status `proposed`, with the rejected option captured in `## Alternatives considered`.

Then record it as a real decision (→ `decisions.md`) so it lands in the decision record, not just the `adr/` file:

```bash
python3 .claude/skills/qtc-dev-scripts/prepend_decision.py \
  "- YYYY-MM-DD [ADR] NNNN <slug> — <decision in one line>. Rejected: <alternative>."
```

### 5. Write the feature spec

When the interview is complete, save to `docs/project/features/YYYY-MM-DD-{slug}.md` using this exact structure:

```markdown
---
title: <Feature title>
status: drafted
created: <YYYY-MM-DD>
related_adrs: []
epics: []
---

# <Feature title>

## Problem statement
<from user's perspective>

## Solution
<from user's perspective>

## User stories
1. As a <actor>, I want <feature>, so that <benefit>
2. ...

## Implementation decisions
<bullet list — modules, interfaces, schemas, contracts, but no file paths or code snippets unless from a validated prototype>

## Testing decisions
<what makes a good test for this feature; which modules will be tested; prior art if any>

## Out of scope
<what is deliberately not part of this feature>

## Further notes
<anything else worth recording>
```

### 6. Update epic links

Feature spec ends with `epics: []` in frontmatter. The decompose skill will populate this later — do not preempt.

### 7. Append a one-line pipeline-log entry

After saving, run (this is a lifecycle breadcrumb → `pipeline-log.md`, not a decision):

```bash
python3 .claude/skills/qtc-dev-scripts/prepend_log.py \
  "- YYYY-MM-DD [BRAINSTORM] Created feature: <title> -> features/YYYY-MM-DD-{slug}.md"
```

### 8. Report

Output the path of the new feature spec and prompt the user: "Run `/qtc-dev-architect features/YYYY-MM-DD-{slug}.md` to sketch the architecture."

## Discipline

- **One question at a time.** Never batch.
- **Glossary is sacred.** Don't drift into synonyms; surface conflicts.
- **No code snippets in the spec** unless they encode a decision more precisely than prose can (state machine, schema, type shape).
- **No file paths in the spec.** Implementation details rot fast.
