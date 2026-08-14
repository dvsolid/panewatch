---
name: qtc-dev-simplify
description: Use as the middle phase of the dev loop — after qtc-dev-execute-task produces a passing implementation and before qtc-dev-verify reviews it. Polishes the working-tree diff for clarity/redundancy via a compact in-process checklist (no sub-agent fan-out, no external skill dependency), re-runs tests, and records the outcome on the task. Conditional — skips trivial diffs. Ralph dispatches this in its own subagent; the user can also invoke directly.
---

# qtc-dev-simplify

Polish a freshly-implemented task's diff in an isolated subagent, then leave it `ready` for verify. Quality only — never changes behavior, never touches tests' assertions.

This skill owns its own review checklist (§3) rather than delegating to the harness's built-in `simplify` skill. That skill fans out to several parallel review sub-agents per pass — thorough, but at a real wall-clock cost, and its behavior isn't pinned to this project (it changes upstream without notice). The checklist below is a fixed, compact, in-process replica: one agent, one pass, same review dimensions, no sub-agent dispatch latency.

## Why this is its own phase

Extracting this into its own subagent (execute → **simplify** → verify) gives it clean, cheap context — just the diff, not execute's full TDD history — and keeps it from hijacking execute's closeout (see the documented stall in `qtc-dev-execute-task`). Verify still runs *after* this phase, so the committed code is always the reviewed code.

## When this runs

- Ralph dispatches this between execute and verify (its §4.5).
- User runs `/qtc-dev-simplify TASK-NNN` directly on a `ready` task that has a `## Implementation` section.

## Process

### 1. Load and gate

- Read `docs/project/tasks/TASK-NNN-*.md`. Confirm `status: ready` and a `## Implementation` section is present (execute's closeout). If either is missing, this phase was dispatched too early — record nothing, return `TASK-NNN: simplify skipped (execute closeout absent)`.
- Inspect the working-tree diff (execute's changes are uncommitted at this point):

```bash
git --no-pager diff --stat HEAD
```

### 2. Triviality check (conditional skip)

Skip simplify when the diff cannot meaningfully benefit:

- A single-line or near-single-line change.
- A pure config / string / asset / frontmatter edit.
- Only test files changed with no production-logic shift.

If trivial → record the skip and you are **done**:

```bash
echo "- Simplify: skipped: <one-line reason>" >> <task_path>
```

Return `TASK-NNN: simplify skipped (<reason>)`.

### 3. Simplify

Otherwise, append the breadcrumb **first** (so a mid-skill stop never loses the record), then run the checklist yourself — in this same subagent, no sub-agent dispatch:

```bash
echo "- Simplify: ran" >> <task_path>
```

Read every file touched in the diff and check each against:

- **Reuse** — for any new helper, pattern, or block of logic, check whether an equivalent already exists elsewhere in the codebase. If so, use it and delete the duplicate instead of keeping both.
- **Redundancy / dead code** — remove unused imports, variables, and branches; collapse duplicate logic; drop comments that just restate what the code already says.
- **Efficiency** — look for avoidable repeated I/O or DB calls, quadratic work where linear suffices, and unnecessary intermediate allocations introduced by this diff.
- **Altitude** — check the abstraction level fits: no one-call-site helper that exists only to be abstract, no inlined logic that duplicates a pattern used elsewhere. Collapse or extract accordingly.
- **Consistency** — naming, formatting, and error handling match the conventions already in the surrounding file.

Apply fixes directly with Edit as you go — a list of suggestions left unapplied is not a completed simplify pass. When a finding is genuinely uncertain (a real improvement, but arguably out of scope or behavior-adjacent), skip it and note why rather than gold-plating the diff.

Constraints:

- **No behavior changes.** If a candidate cleanup would alter observable behavior, skip it — that belongs to a follow-up task, not simplify.
- **Do not weaken tests.** Refactoring test setup for clarity is fine; changing what an assertion checks is not.

### 4. Re-test gate

After simplify returns, re-run the suite via the shared gate. Read `CLAUDE.md` for the exact command — **use the same command string execute-task and verify use**, since the gate cache is keyed on the literal command text; a paraphrased or stale command misses the cache even when the tree is identical. The gate caches its verdict against the exact command + tree state, so if this diff made no edits (or edits identical in effect to what execute last verified), this reuses execute's final regression run instead of re-executing the whole suite:

```bash
python3 .claude/skills/qtc-dev-scripts/append_review.py gate <task_path> "swift test"
```

One suite, one call — SPM has no per-stack split. Pass `swift test` verbatim; do not add
`--filter` or extra flags here, or the cache key stops matching execute-task's entry.

- **`VERDICT: GREEN`** → done. Leave `status: ready`. Do **not** commit and do **not** flip status — verify owns the gate to `done`.
- **`VERDICT: RED`** → simplify introduced a regression. Fix it (or revert the specific offending cleanup) and re-run until green. Never leave the tree red for verify.

Return `TASK-NNN: simplify ran`.

## Discipline

- **Quality only — zero behavior change.** Tests must be as green after as before, for the same reasons.
- **Never commit, never flip status.** This phase hands a polished, `ready` tree to verify; verify is the only path to `done`.
- **Breadcrumb before checklist.** Write the `- Simplify:` line before starting the review, so an early stop is harmless.
- **Conditional.** A trivial diff gets a recorded skip, not a wasted polish pass.
- **No sub-agent fan-out.** This phase runs the checklist itself, in-process. Don't dispatch review sub-agents for it — that's exactly the latency/dependency this replaced.
