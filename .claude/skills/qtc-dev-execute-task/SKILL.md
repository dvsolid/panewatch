---
name: qtc-dev-execute-task
description: Use when implementing a single atomic task from docs/project/tasks/ via TDD red-green-refactor. Cuts a tracer-bullet vertical slice. Pauses with blocked-by-human if the test seam is wrong or a destructive decision is needed mid-execution. The Ralph loop calls this in a subagent; the user can also invoke directly.
---

# qtc-dev-execute-task

Implement one atomic task. TDD discipline. One acceptance item at a time. Refactor only after all green.

See [TDD-DISCIPLINE.md](TDD-DISCIPLINE.md) for the full rules.

## When this runs

- Ralph loop dispatches this in a subagent.
- User invokes `/qtc-dev-execute-task TASK-NNN` directly for manual mode.

## Process

### 1. Load task

- Read `docs/project/tasks/TASK-NNN-*.md`. If multiple match, fail loudly.
- Validate frontmatter `status == ready`. If not: abort with current status.
- Validate all `depends_on` tasks have `status: done`. If not: abort with the names of unresolved blockers.

### 2. Flip status

```bash
python .claude/skills/qtc-dev-scripts/mark_status.py <task_path> in-progress
```

Also set `claimed_at: "<ISO-datetime>"` and `claimed_by: "ralph-<session-id or 'manual'>"` in frontmatter so the Ralph loop can detect orphaned tasks. Save before proceeding.

### 3. Read context

- Task body (slice, acceptance, test seam).
- **If `## Review notes` is present** (re-run after a verify failure): read it now and treat every listed issue as a concrete requirement for this pass. These are not optional suggestions — they are the delta between the last attempt and passing.
- Linked epic and feature for upstream context.
- `memory/glossary.md` so test names use project vocabulary.
- `memory/failure-patterns.md` — if any pattern matches what we're about to do, surface it.
- Existing code at the test seam.

### 4. Verify the test seam

The task's declared test seam is binding. If a brief code reading reveals it's the wrong seam (e.g., the named class doesn't exist, or the seam can't actually exercise the slice), **pause**:

- Flip frontmatter `status: blocked-by-human`.
- Populate `blocker_question:` with a one-sentence question.
- Append to body: `## Blocked by human\n<question and what you found>`.
- Return.

Do not invent a different seam without user approval.

### 5. TDD per acceptance item

For each `- [ ]` in `## Acceptance`, in order:

#### Red
Write **one** failing test that exercises this acceptance item through the public interface at the declared seam. Run it. Confirm it fails for the reason you expect (not import error, not syntax error — fail because the behavior doesn't exist).

#### Green
Write the **minimal** implementation that makes the test pass. No anticipation of future tests. No speculative features.

Run the **focused test** (seam only, e.g. `swift test --filter TmuxCoreTests.DiscoveryTests`). Confirm it passes. Do **not** run the full suite here — that is deferred to the end.

#### Tick
Mark the acceptance item `- [x]` in the task body. Move to the next item.

### 6. Refactor (only after all acceptance items are green)

When every acceptance item is `[x]`:

- Look for duplication across the new tests/code.
- Look for opportunities to deepen modules (extract a deep module if the deletion test passes).
- Apply changes. Re-run the focused test after each refactor step. Never refactor while RED.

Once refactor is complete, run the **full test suite** once as a regression check, via the shared gate so the verdict is cached for simplify/verify to reuse if the tree doesn't change again before they run:

```bash
python3 .claude/skills/qtc-dev-scripts/append_review.py gate <task_path> "<command from CLAUDE.md>"
```

Fix any failures before proceeding — `VERDICT: RED` means something broke.

### 7. Append implementation notes to task

After the refactor pass — **before** any further skill invocation — append to the task body:

```markdown
## Implementation
- Files touched: <paths>
- Tests added: <paths>
- Notes: <anything a reviewer needs to know>
```

### 8. Hand off to verify

Write the closeout **now** — `## Implementation` (§7), then flip status and log the breadcrumb here. This is the end of execute; simplify and verify are separate downstream phases that operate on the diff you leave behind.

First confirm `## Implementation` is present:

```bash
grep -q "^## Implementation" <task_path> \
  || { echo "STOP: ## Implementation section missing — complete step 7 first"; exit 1; }
```

If it exits non-zero, go back to §7. Then flip status:

```bash
python3 .claude/skills/qtc-dev-scripts/mark_status.py <task_path> ready
```

Clear `claimed_at` and `claimed_by` (set both to `""`). The Ralph loop picks up the task; in manual mode, the user runs `/qtc-dev-verify TASK-NNN`.

Run the pipeline-log script to record the execute breadcrumb (file-locked, so concurrent writers won't interleave):

```bash
python3 .claude/skills/qtc-dev-scripts/prepend_log.py \
  "- $(date +%Y-%m-%d) [EXECUTE] TASK-NNN: <one-line summary of what was built>"
```

Keep the summary ≤ ~100 characters. Implementation details belong in `## Implementation` in the task file — not in the log.

**If this pass involved a real decision, also record it** (→ `decisions.md`, via `prepend_decision.py`): a mid-task scope/requirement change (`[REQ CHANGE]`), a choice between genuine alternatives discovered while building, or an exploratory spike (`[SPIKE]`/`[EXPERIMENT]`). The `[EXECUTE]` breadcrumb above is *what* was built; a decision entry is *why* it diverged from the plan. Skip this when the task was built as specified with no judgment calls — most tasks.

**This is execute's final step.** Do not run simplify here — it is now a separate phase (`qtc-dev-simplify`) that runs *after* execute and *before* verify, in its own subagent. Extracting it removed the stall it used to cause when its completion summary ended the turn before this closeout. Execute's job ends once `## Implementation` is written and status is `ready`.

## Failure modes

| Symptom | Action |
|---|---|
| Test seam doesn't exist or can't exercise the slice | Block with question (§4) |
| All depends_on not done | Abort with status report |
| Test fails after green for an unrelated reason | Investigate; do not silently retry |
| Two acceptance items can't be tested independently | Block with question — likely the task needs splitting |
| Irreversible or production-impacting action required (rm -rf, force-push, non-additive migration) | Block with question — never run destructively in autonomous mode |
| Additive Alembic migration (new table, new nullable/defaulted column) | Normal work — proceed without blocking |
| Non-additive migration (drop column, data loss, `--unsafe`) | Block with question |

## Discipline

- **One test, one minimal impl, repeat.** No horizontal slicing.
- **Tests exercise the public interface.** Never mock internals of the module under test.
- **Never refactor while RED.** Get to green first.
- **Failure patterns from memory are checked once at start**, not consulted reactively.
