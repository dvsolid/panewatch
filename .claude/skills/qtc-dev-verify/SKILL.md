---
name: qtc-dev-verify
description: Use when verifying a task implementation produced by qtc-dev-execute-task. Runs tests, reads the diff with fresh reviewer eyes (no execute context), checks that tests target behavior not implementation, and either passes the task to done or returns it to ready with notes. Hits blocked-by-human at the second failure.
---

# qtc-dev-verify

Fresh-eyes reviewer pass on an executed task. No anchoring bias from execute.

## When this runs

- Ralph loop dispatches this in a fresh subagent after execute returns.
- User runs `/qtc-dev-verify TASK-NNN` directly.

In **both** cases this skill owns the full execute→verify retry cycle. It dispatches execute and re-verifies in subagents so the calling thread (Ralph or user) never touches code.

## Process

### 1. Load task and implementation

- Read `docs/project/tasks/TASK-NNN-*.md`. Confirm `status: ready`.
- Check for `## Implementation` section:

```bash
grep -q "^## Implementation" <task_path>
```

  - **Present** → read the files listed in `Files touched` and `Tests added`. Proceed to §1.5.
  - **Missing** → the prior execute stopped before writing §7. Bounce inline, at most once — but **do not** tell it to re-run the full execute skill (that triggers a fresh TDD cycle and wasteful git-log archaeology to reconstruct what was done). Dispatch a *focused* subagent that just reads the diff and writes the section:
    1. `Agent(subagent_type="qtc-dev-ralph-simplifier", prompt="A qtc-dev-execute-task run on TASK-NNN-{slug} finished the code but stopped before writing its ## Implementation section. Do NOT re-run the TDD cycle, do NOT do git-log archaeology, do NOT change any code. Run `git diff --stat HEAD` and `git status --short` once to see exactly what changed, then append a ## Implementation section (Files touched + Tests added straight from the diff; Notes: one line) to docs/project/tasks/TASK-NNN-{slug}.md. Ensure frontmatter status is `ready` with claimed_at/claimed_by cleared. Return.")` — mechanical touch-up from an existing diff, not fresh implementation, so it borrows ralph's simplify-tier agent rather than the executor.
    2. Wait for return, then re-run the grep.
    3. Section now present → proceed to §1.5. Still missing → fail: run `append_review.py fail` with note "## Implementation section still missing after one bounce" and skip to §5.

- Do NOT read execute's intermediate reasoning. Fresh eyes.

### 1.5. Simplify-record check (advisory — never bounce, never fail)

The `qtc-dev-simplify` phase runs between execute and verify and records a Simplify outcome. Check it, but treat its absence as advisory only: it is bookkeeping, not a code defect, and verify independently re-reviews the full diff in §3 regardless of whether simplify ran. Do **not** bounce and do **not** call `append_review.py` on this.

```bash
grep -q '^- Simplify:' <task_path>
```

- **No match** → the simplify phase didn't run or didn't finish. Note it in `## Review notes` ("Simplify record absent — simplify phase skipped or stopped early") and proceed to §2.
- **Match reading `skipped:`** with a non-trivial diff (multiple files or substantial new logic) → note the questionable skip in `## Review notes`, but do not block.
- **Otherwise** → proceed to §2.

### 2. Run tests and static checks

#### 2a. The test gate (mechanical, authoritative)

Read `CLAUDE.md` to find the project's full test suite command, then run it via the gate — **do not run the suite yourself first.** `gate`'s exit code is the only verdict that counts; running it manually beforehand duplicates a ~50s test run for zero additional signal.

```bash
python .claude/skills/qtc-dev-scripts/append_review.py gate <task_path> "<command from CLAUDE.md>"
```

The command runs from the repo root via shell; exit 0 → GREEN, non-zero → RED. (`pass` in §5 reuses this verdict instead of re-running the suite, as long as the tree hasn't changed since — so gate and pass together still cost only one real test run, not two.)

- **`VERDICT: GREEN`** → suite ran clean. Proceed to §2b.
- **`VERDICT: RED`** → suite failed (or could not run). **Fail the review** (retryable) — go to §5 `fail`. The project keeps `main` green, so there is no such thing as a "pre-existing" or "unrelated" failure: any RED is attributable to this change. You have **no authority** to pass on RED — and the `pass` verb re-runs the gate and will refuse anyway.

#### 2b. Reviewer checks (not covered by the gate)

The tiers below remain **your judgment** — run the ones that apply, and **fail the review** (§5 `fail`) with the output in the notes if any fail:

Read `CLAUDE.md` for the project's build and lint commands. Common tiers:

| Tier | When |
|---|---|
| Build warnings | any source file changed — `swift build -Xswiftc -warnings-as-errors` |
| Concurrency | any type crossing an actor or `Sendable` boundary changed |

**Warnings gate**: `swift test` passes with warnings present, so the suite alone will not catch
them. Run the warnings-as-errors build whenever source changed; a new warning is a review fail.

**Concurrency gate**: this project is Swift 6 with strict concurrency. If the diff adds or
changes a type that crosses an actor boundary or is stored in shared state, confirm it is
`Sendable` (or explicitly isolated) and that the reasoning is stated in the task's
`## Implementation`. A type made `@unchecked Sendable` without a written justification is a
**blocking** fail — it compiles and passes tests while leaving a real data race.

**tmux-dependent tests**: any test that shells out to real `tmux` is environment-dependent and
must not be in the default suite. Confirm such tests are either driven through a fake/injected
command runner, or explicitly skipped when `tmux` is absent. A suite that only passes on a
machine with live tmux sessions is a blocking fail.

### 3. Behavior-vs-implementation review

For each test in `Tests added`, read it and ask:

1. Does it exercise the **public interface** declared in the task's test seam?
2. Would it pass if the internal implementation were rewritten without changing behavior?
3. Does it mock collaborators of the module under test? (Red flag.)
4. Is the assertion specific to the symptom, or generic ("didn't throw")?

Score:

- All four pass → **review passes**.
- 1–2 fail → **request fix** (review fails, retryable).
- 3+ fail → **request fix with specific notes** (review fails, retryable).

### 4. Slice-vs-acceptance review

For each `- [x]` in `## Acceptance`:

- Is the marked behavior actually testable from the new tests?
- Does the implementation deliver the observable behavior described?

If any acceptance item is checked but unsupported → review fails.

### 5. Apply outcome

**Pass**:

```bash
python .claude/skills/qtc-dev-scripts/append_review.py pass <task_path> "Tests: N added, all green. Behavior coverage: complete." "<same command as §2a>"
```

`pass` **re-runs the gate** and refuses (`REFUSED: gate is RED`, non-zero exit) unless it is GREEN — so it cannot mark a task done while the suite fails. If it refuses, the suite is not actually green: treat it as a RED and route to `fail`; **do not** work around it.

Then run the pipeline-log script (file-locked; safe under concurrent writers):

```bash
python3 .claude/skills/qtc-dev-scripts/prepend_log.py \
  "- $(date +%Y-%m-%d) [VERIFY] TASK-NNN passed"
```

**Fail (first or second)**:

```bash
python .claude/skills/qtc-dev-scripts/append_review.py fail <task_path> "Issue 1|Issue 2|Suggested fix: ..."
```

`append_review.py fail` increments `review_failures` and auto-escalates to `blocked-by-human` on the second failure. Set `blocker_question` manually if further human context is needed. For an infrastructure failure that no retry can fix, use `append_review.py blocked <task_path> "<reason>"` instead — escalates to a human without consuming a strike.

**Retryable fail — dispatch the fix as a subagent:**

After any retryable fail (`review_failures < 2`):

1. Dispatch execute subagent: `Agent(subagent_type="qtc-dev-ralph-executor", prompt="Run the qtc-dev-execute-task skill on TASK-NNN-{slug}. Follow the skill exactly. ## Review notes in the task file is your fix list. Return when done.")`
2. Wait for return.
3. Re-read task frontmatter. If `status: blocked-by-human` → stop and report. Otherwise proceed.
4. Dispatch a fresh verify subagent: `Agent(subagent_type="qtc-dev-ralph-verifier", prompt="Run the qtc-dev-verify skill on TASK-NNN-{slug}. Fresh eyes — do not read the execute subagent's reasoning.")`
5. Wait for return. Read outcome from task frontmatter and proceed to §6.

This applies regardless of whether verify was called by Ralph or directly by the user. The calling thread never touches code.

### 6. Report

Return exactly **one line** — nothing more:

- Pass: `TASK-NNN: pass`
- Fail escalated to human: `TASK-NNN: blocked-by-human — see blocker_question in task file`

All findings are already in the task file via `append_review.py`. Do **not** echo them back here.

## Discipline

- **Fresh eyes.** Don't read execute's reasoning. Read the artifacts.
- **Behavior over implementation.** A test that tests internals is a fail signal even if it passes.
- **Specific, actionable notes.** "Make it better" is not a review.
- **Two strikes, then human.** The second failure is the signal that something deeper is off — don't burn cycles on a third autonomous retry.
- **Never echo findings to the caller.** The task file is the only record of findings. Verbose summaries in the calling thread pollute context and invite inline fixes that bypass execute's subagent boundary.
- **The only path to `done` is `append_review.py pass`.** It runs the gate and refuses unless GREEN. Never flip a task to `done` with `mark_status.py done` or by hand-editing frontmatter — that bypasses the gate and is exactly the false-pass this skill prevents.
