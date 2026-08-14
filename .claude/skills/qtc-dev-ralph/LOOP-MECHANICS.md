# Loop Mechanics

Operational details for the Ralph loop. The SKILL.md gives the process; this is the why and the edge cases.

## Why fresh subagents per phase

Execute and verify must be done with different cognitive postures:

- **Execute** is constructive — making the code work, holding the slice in mind, optimizing for green tests.
- **Verify** is adversarial — looking for ways the implementation might be wrong even though tests pass.

Reusing the same agent context for both leads to verify rubber-stamping execute, because the agent saw what was done and how it got there. Fresh subagent = no anchoring.

## Why status in frontmatter, not in-memory

The loop body can crash, the user can interrupt, the parent session can hit context limits. After any of those, the next invocation reads the same task files and picks up exactly where it left off. Frontmatter is durable; in-memory state isn't.

This also means: a human can edit a task file by hand (flip `blocked-by-human` back to `ready` after answering the question, fix a dependency, split a task) and the loop will respect that on the next pass.

## Why two strikes, not three

A single verify failure is signal — could be one missed acceptance item, easy to fix. A second failure on the same task means execute didn't internalize the first round's feedback. At that point, a third autonomous attempt usually loops on the same problem; the surface is wrong, the seam is wrong, or the acceptance item is ambiguous. Humans diagnose those faster than agents do.

## Dependency satisfaction

`depends_on` is checked at the moment a task is picked, not when the loop starts. This means: if task A completes during the loop, task B (which depends on A) becomes pickable in the very next iteration without restarting.

## When the loop should stop without a blocker

- No ready tasks (success — epic done if scoped).
- All ready tasks have unsatisfied dependencies (deadlock — log and ask user).
- Context budget low (let the user see partial progress; do not silently degrade).

## When the loop should NOT pause

- A single execute failure → retry once via verify failure path.
- A flaky test → execute should diagnose, not the loop.
- A long-running test → that's a test problem, not a loop problem.

## Why the whole-branch review base is captured in memory, not frontmatter

Every other piece of loop state lives in task frontmatter, precisely because the loop body can crash and the next invocation must pick up unaided (see "Why status in frontmatter, not in-memory" above). `RUN_START_SHA` — the base commit the post-loop whole-branch review (§6.2) diffs against — is the one deliberate exception.

It has to be in-memory, because it answers a question frontmatter can't: "what did *this run* add?" A `RUN_START_SHA` written to a file would need its own lifecycle — when does it get cleared, what happens if two runs overlap — for a value that only ever needs to survive as long as the run that captured it.

A remote-relative base (`origin/main...HEAD`) would answer a different and wrong question here — "is there anything unmerged at all," including commits from before this run. It is also unavailable: this repo has no remote.

This is safe only because §6.2 fires exclusively at the tail of the same continuous invocation that captured `RUN_START_SHA` in §0. A crashed run never reaches §6.2 — it dies mid-loop, well before the post-loop gates. A resumed run (the next `/qtc-dev-ralph` invocation, picking up tasks the crashed run left `ready` or `in-progress`) is a fresh invocation with its own fresh capture at its own §0 — it never needs the previous run's start SHA, because it's reviewing its own new commits, not reconstructing an old run's. If `RUN_START_SHA` is ever missing when §6.2 runs (which shouldn't happen in a normal single continuous invocation, but is checked defensively), the gate skips rather than guessing a base.

## Anti-patterns

- **Loop modifies code directly.** Never. All code lives in execute's subagent.
- **Loop reads execute's reasoning.** No — read the artifacts (frontmatter, code, tests).
- **Loop assumes serial = no concurrency.** Even in serial mode, other agents (human, other Claude sessions) might be touching the same files. Re-read frontmatter at every decision point.
