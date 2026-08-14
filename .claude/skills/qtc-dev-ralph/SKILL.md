---
name: qtc-dev-ralph
description: "Use when autonomously executing all ready tasks for an epic (or globally). Picks the next ready task with all dependencies resolved, then runs three subagent phases per task — qtc-dev-execute-task, qtc-dev-simplify, qtc-dev-verify — advances status, and loops until no ready tasks or any task hits blocked-by-human. Runs tasks one at a time, serially. Also supports standalone mode: invoke with a free-text description (not an EPIC-NNN ID) to run a single small task without a feature spec or epic."
---

# qtc-dev-ralph

Autonomous task driver. Pick → execute → verify → loop. Inspired by Geoff Huntley's Ralph Cycle.

See [LOOP-MECHANICS.md](LOOP-MECHANICS.md) for the operational details.

## When this runs

- User invokes `/qtc-dev-ralph` (global scan) or `/qtc-dev-ralph EPIC-NNN` (scoped to one epic).
- User invokes `/qtc-dev-ralph <description>` with free text (not an epic ID) — standalone mode.

## Process

### 0. Mode detection

Inspect the argument:

- **No argument** → epic-loop mode, global scan. Skip to §1.
- **Matches `EPIC-\d+`** (e.g. `EPIC-014`) → epic-loop mode, scoped. Skip to §1.
- **Anything else** → standalone mode. Treat the full argument as a task description. Proceed to §SA. After §SA completes and a task file is written, resume at §3 using the allocated task ID.

**Before branching either way**, capture `RUN_START_SHA` via `git rev-parse HEAD`. This is in-memory state, held for the lifetime of this invocation only — it's the base for the post-loop whole-branch review (§6.2). See LOOP-MECHANICS.md for why this one piece of state is allowed to live outside frontmatter.

---

### SA. Standalone intake (standalone mode only — skip if epic-loop)

#### SA.1 Derive acceptance criteria

Using your own judgment as an LLM, derive a concrete, checkable list of acceptance criteria from the description. Each criterion must be independently verifiable. Aim for 2–3 items; 4+ is a signal the task may be too large.

#### SA.2 Scope gate

Count the derived criteria. If ≥ 4:

> This looks like more than one task — consider using the full pipeline (`/qtc-dev-brainstorm` → `/qtc-dev-architect` → `/qtc-dev-decompose`). Proceed standalone anyway? (yes/no)

Wait for the user's response. If no → exit cleanly. No file is written.

#### SA.3 Confirm derived criteria

Present the criteria to the user in a single exchange:

> **Derived acceptance criteria:**
> 1. …
> 2. …
>
> Proceed?

Wait for yes/no. If no → exit cleanly. No file is written.

#### SA.4 Allocate task ID

Run:
```bash
python .claude/skills/qtc-dev-scripts/allocate_id.py task
```

Capture the printed `TASK-NNN` ID. Never assign an ID manually.

#### SA.5 Write task file

Derive a kebab-case slug from the task title (max 6 words). Write to `docs/project/tasks/TASK-NNN-{slug}.md`:

```markdown
---
id: TASK-NNN
title: "<title>"
type: task
status: ready
epic: ""
depends_on: []
standalone: true
created: <YYYY-MM-DD>
blocker_question: ""
review_failures: 0
claimed_at: ""
claimed_by: ""
---

# <title>

## Acceptance

- [ ] <criterion 1>
- [ ] <criterion 2>
…

## Test seam

Manual: invoke the change and confirm each acceptance criterion holds.
```

#### SA.6 Dispatch execute → simplify → verify

Resume at §3 (Dispatch execute) using `TASK-NNN` from §SA.4 as the task to execute. The full §3 → §4 → §4.5 → §5 → §6 flow applies (execute → simplify → verify). On verify pass, commit with:

```bash
git add -- Sources/ Tests/ Package.swift
git commit -m "TASK-NNN: <title>"
```

The whole-branch review (§6.2) applies as usual after the task completes. Standalone tasks have no epic file, so the reviewer prompt's `{EPIC_FILE}` is simply omitted — the task file's own `## Acceptance` is self-sufficient input.

> **Standalone tasks have no parent epic** — `epic:` is intentionally empty. Do not attempt to run the completion cascade (§6.1) for epic or feature promotion.

---

### 1. Validate scope

- If an epic ID is provided: confirm `docs/project/epics/EPIC-NNN-*.md` exists. Read its task links.
- Otherwise: glob `docs/project/tasks/*.md` for the candidate set.
- Filter to `status: ready`.
- Filter out tasks whose `depends_on` are not all `status: done`.
- If the remaining set is empty: run `python3 .claude/skills/qtc-dev-scripts/prepend_log.py "- YYYY-MM-DD [RALPH] Run completed: no ready tasks"` and exit.

**Stale in-progress recovery**: before filtering, scan for any task with `status: in-progress`. If `claimed_by` identifies this loop's own session and `claimed_at` is recent (< 2 hours), the task is actively running — skip it. If `claimed_at` is absent, expired (> 2 hours old), or belongs to a different session, the task was orphaned. Log a warning listing each orphaned task. Ask the user to flip them back to `ready`, or pass `--recover` to reset all stale `in-progress` tasks to `ready` automatically.

### 2. Pick next task

Order by:
1. Tasks with no dependencies first (root tasks).
2. Tasks unlocking the most downstream tasks (compute on-the-fly from `depends_on` edges).
3. Lower TASK-NNN first as tiebreaker.

### 3. Dispatch execute

- Dispatch a subagent via the Agent tool with `subagent_type=qtc-dev-ralph-executor` (sonnet, high effort — real cross-layer implementation work). Prompt:
  > "Run the `qtc-dev-execute-task` skill on `TASK-NNN-{slug}`. Follow the skill exactly. Return when done. Do not invoke verify."
- Wait for return.

### 4. Check post-execute status

After execute returns, re-read the task frontmatter:

- If `status: blocked-by-human` → log it, skip simplify and verify, break loop. Report to user.
- If `status: ready` and `## Implementation` section present → proceed to §4.5 (simplify).
- If `status: in-progress` (execute stopped before completing its §7–§8 closeout — rare now that simplify is no longer a mid-execute sub-skill):
  - Log: `"Execute returned with status still in-progress — closeout incomplete. Resetting to ready."`
  - Run `python3 .claude/skills/qtc-dev-scripts/mark_status.py <task_path> ready` and clear `claimed_at`/`claimed_by`.
  - Proceed to §4.5. If `## Implementation` is missing, verify §1 will detect it and dispatch a focused (no-archaeology) bounce.
- Otherwise → log as anomaly, treat as verify failure.

### 4.5. Dispatch simplify

Polish the implemented diff before verify gates it, so the committed code is always the reviewed code.

- Dispatch a subagent with `subagent_type=qtc-dev-ralph-simplifier` (sonnet, medium effort — polishing an already-green diff). Prompt:
  > "Run the `qtc-dev-simplify` skill on `TASK-NNN-{slug}`. Follow the skill exactly. Return when done. Do not invoke verify."
- Wait for return. The skill skips trivial diffs (recording the skip), polishes substantive ones, and re-runs tests — it leaves the task `ready` either way and never commits. Proceed to §5 regardless of skip/ran outcome.

### 5. Dispatch verify (fresh subagent)

- Dispatch a separate subagent with `subagent_type=qtc-dev-ralph-verifier` (sonnet, high effort — the quality gate). Prompt:
  > "Run the `qtc-dev-verify` skill on `TASK-NNN-{slug}`. Fresh eyes — do not read the execute subagent's reasoning. Just the artifacts."
- Wait for return.

### 6. Read outcome and loop

Re-read task frontmatter:

> **Note**: `qtc-dev-verify` now self-contains the execute→verify retry cycle. It dispatches execute and re-verifies in subagents on fail, so it returns only when the task is `done` or `blocked-by-human`. `status: ready` after verify returns is an anomaly — treat it as a verify failure.

- `status: done` → commit, run completion cascade (§6.1), then loop back to §1.
  - Stage source files: `git add -- Sources/ Tests/ Package.swift` (do NOT use `git add -A` — that sweeps env files and generated artifacts; under SPM `.build/` is large and rebuilt constantly)
  - Commit: `git commit -m "TASK-NNN: <title>"`
  - If the commit fails (e.g. nothing to stage, pre-commit hook error), log the failure and continue the loop — a missed commit is not a reason to stop.
  - **Vault note**: `docs/project/` is a gitignored Obsidian vault (operational state by design). Task status, decisions, and ADRs written there are **not** version-controlled alongside source commits. This is an accepted trade-off; the vault is the live system-of-record. Do not attempt to `git add docs/project/`.

#### 6.1 Completion cascade

After each task reaches `done`, check whether parent entities are now complete:

1. **Epic**: read the task's `epic:` frontmatter field to find the epic file. Read all `- [[TASK-NNN]]` links from the epic body. If every linked task has `status: done`, run `python3 .claude/skills/qtc-dev-scripts/mark_status.py <epic_path> done` and run `python3 .claude/skills/qtc-dev-scripts/prepend_log.py "- YYYY-MM-DD [RALPH] EPIC-NNN complete"`.
2. **Feature**: if the epic just flipped to `done`, find the feature file via the epic's `feature:` frontmatter. Read all `epics: [...]` links. If every linked epic has `status: done`, flip the feature `status: decomposed` → `status: complete` and run `python3 .claude/skills/qtc-dev-scripts/prepend_log.py "- YYYY-MM-DD [RALPH] <feature-slug> complete"`.
- `status: ready` (verify failed, retryable) → loop back to §1 (it'll be picked up by the next pass or wait its turn).
- `status: blocked-by-human` → break loop, report.

**Per-task commit behavior is unchanged** — commits happen after each verify pass (above); the whole-branch review runs after the loop exits over the cumulative diff, not per iteration.

#### 6.2 Post-loop whole-branch review

Fires **once**, after the loop exits — a holistic pass over everything *this run* committed, which no single task's fresh-eyes `qtc-dev-verify` can see since each of those only ever read one task's diff. This is the **final gate**: nothing runs after it but the run summary.

**Step 1: Diff check**

Run:

```bash
git diff --name-only RUN_START_SHA...HEAD
```

(the `RUN_START_SHA` captured in §0 — deliberately **not** a remote ref like `origin/main`. This gate only wants what *this run* added, and `RUN_START_SHA` says exactly that. It is also the only form that works here: tmuxer-mac is a local repo with no remote, so any `origin/...` range would error or silently return empty.)

Filter to paths starting with `Sources/` or `Tests/`, plus `Package.swift`.

- If **no qualifying paths**, **`RUN_START_SHA` wasn't captured**, or **zero tasks reached `done` this run** → record outcome `branch_review: skipped (no changes this run)` and proceed to §6.3.
- Otherwise → continue to Step 2.

**Step 2: Dispatch the reviewer**

Dispatch a subagent with `subagent_type=qtc-dev-ralph-branch-reviewer` (opus, xhigh effort — the most capable available model, for the one review that sees the whole run). Fill in [branch-review-prompt.md](branch-review-prompt.md) with the list of tasks that reached `done` this run, the epic file if scoped, `BASE_SHA=RUN_START_SHA`, `HEAD_SHA=`current HEAD.

Wait for return.

**Step 3: Read outcome**

Read the literal last line of the reviewer's response — `BRANCH_REVIEW_VERDICT: CLEAN` or `BRANCH_REVIEW_VERDICT: FINDINGS <K>` (this is the same machine-parseable marker the Pi-native driver keys off; don't fuzzy-match the prose Assessment line — a substring check on "Critical" would also match the `#### Critical (Must Fix)` heading even when empty).

- **`CLEAN`** → record outcome `branch_review: clean`. Proceed to §6.3.
- **`FINDINGS <K>`** → continue to Step 4.
- **Marker missing or unparseable** → treat as a failure, not as clean: record outcome `branch_review: blocked-by-human (reviewer returned no parseable verdict)`, halt, and report the reviewer's raw output to the user. Never default to clean on a missing marker — that silently disables the gate.

**Step 4: Dispatch one fixer**

Dispatch a single subagent with `subagent_type=qtc-dev-ralph-branch-fixer` (sonnet, high effort), filling in [branch-fix-prompt.md](branch-fix-prompt.md) with the complete Critical + Important findings list. **One dispatch for all findings, never one per finding** — per-finding fixers each rebuild context and re-run tests for no benefit.

Wait for return.

**Step 5: Commit the fix wave**

```bash
git add -- Sources/ Tests/ Package.swift
git commit -m "Post-loop branch review: fixed <K> findings (<TASK-NNN,...>)"
```

Never `git add -A`. If nothing is staged (the fixer disputed every finding), log that and still proceed to Step 6 — the re-review will confirm nothing needed to change.

**Step 6: Dispatch one scoped re-reviewer**

Dispatch a subagent with `subagent_type=qtc-dev-ralph-branch-re-reviewer` (sonnet, medium effort — a scoped re-review of a fix diff is cheap-to-mid tier work), filling in [branch-re-review-prompt.md](branch-re-review-prompt.md) with the same findings list, `FIX_BASE_SHA=`the HEAD the reviewer saw in Step 2, `HEAD_SHA=`current HEAD (after the fix commit).

Wait for return.

**Step 7: Adjudicate**

Read the literal last line of the re-reviewer's response — `BRANCH_REVIEW_FIX_VERDICT: CLEAN` or `BRANCH_REVIEW_FIX_VERDICT: RESIDUAL <summary>` (same marker convention as Step 3; a missing/unparseable marker is treated the same as `RESIDUAL`, never as clean).

- **`CLEAN`** → record outcome `branch_review: fixed (<K> findings addressed)`. Proceed to §7.
- **`RESIDUAL <summary>`, or the marker is missing/unparseable** → record outcome `branch_review: blocked-by-human (<residual summary>)`. Halt and report the residual findings directly to the user. Do **not** proceed to §7's summary. **No second fix wave** — halt rather than retry indefinitely.

### 7. Loop termination

Exit when any of:

- No `ready` tasks with satisfied dependencies remain.
- Any task hits `blocked-by-human`.
- User interrupts (Ctrl+C from outside; the loop checks no internal signal).

Run the log script with the run summary:

```bash
python3 .claude/skills/qtc-dev-scripts/prepend_log.py \
  "- YYYY-MM-DD [RALPH] Run completed: N done, M blocked-by-human, K still ready; branch_review: clean|fixed|blocked"
```

Report to the user with a table of completed task IDs, any blockers' questions, and the whole-branch review outcome (including any residual findings if it ended `blocked-by-human`).

## Discipline

- **One task at a time, serially.** The loop picks one ready task, runs execute→verify to a terminal outcome, then picks the next.
- **Fresh subagent per task per phase.** No context leak between execute, simplify, and verify.
- **Status is the source of truth.** The skill reads frontmatter; it does not maintain in-memory state across the loop body.
- **No code edits.** This skill only orchestrates. All code touches happen via execute's subagent or the post-loop branch-review fix wave — never the loop body itself.
- **Commit on verify pass, not on execute.** Committing before verify would record broken or incomplete work. The commit captures the verified, accepted state.
- **Never bypass blocked-by-human.** Once a task is blocked, the loop stops until a human flips it back to `ready` (after answering `blocker_question`).
