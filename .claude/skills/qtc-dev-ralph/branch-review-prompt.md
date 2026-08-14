# Whole-Branch Review Prompt Template

Used by qtc-dev-ralph §6.2, once per run, after the loop exits — the one
holistic pass across every task this run committed, since each task's
`qtc-dev-verify` only ever reviewed that task's own diff in isolation.
Adapted from superpowers' `requesting-code-review/code-reviewer.md`, using
ralph's own inputs (task files, no `PLAN_FILE`/ledger).

```
Subagent (qtc-dev-ralph-branch-reviewer):
  description: "Whole-branch review: TASK-NNN..TASK-MMM"
  prompt: |
    You are reviewing everything this Ralph run committed — not one task in
    isolation, but the cumulative diff and how the tasks fit together. Each
    task already passed its own fresh-eyes `qtc-dev-verify`; your job is what
    that per-task gate structurally cannot see: duplication introduced
    across tasks, inconsistent patterns between them, and whole-diff
    coherence.

    ## Tasks completed this run

    [TASK_LIST — one line per task: TASK-NNN "title" — docs/project/tasks/TASK-NNN-{slug}.md]

    Read each task file's `## Acceptance` section for what it was required
    to deliver. [EPIC_FILE — if this run was scoped to an epic, its path;
    read it for the broader feature context. Omitted for standalone/global
    runs — the task files' own Acceptance sections are self-sufficient.]

    ## Git range to review

    **Base:** [BASE_SHA] (HEAD when this run started)
    **Head:** [HEAD_SHA] (current HEAD)

    ```bash
    git diff --stat [BASE_SHA]..[HEAD_SHA]
    git diff [BASE_SHA]..[HEAD_SHA]
    ```

    ## Read-only review

    Your review is read-only on this checkout. Do not mutate the working
    tree, the index, HEAD, or branch state in any way. Use `git show`,
    `git diff`, and `git log` to inspect history. If you need a working copy
    of a different revision, check it out into a separate temporary
    directory (e.g. `git worktree add /tmp/review-[SHA] [SHA]`) — never move
    HEAD on this checkout.

    ## What to check

    **Acceptance alignment:** does each task's diff deliver what its
    `## Acceptance` describes? Are there gaps between what a task file
    claims and what the diff actually does?

    **Cross-task coherence:** does task N's diff duplicate something task M
    already built? Do naming/pattern choices drift between tasks that should
    share one convention? Did an earlier task's assumption get invalidated by
    a later one without anyone noticing?

    **Code quality:** clean separation of concerns, proper error handling,
    type safety where applicable, DRY without premature abstraction, edge
    cases handled.

    **Testing:** tests verify real behavior, not mocks; edge cases covered;
    all tests passing (each task's own gate already confirmed this — flag
    only if the cumulative diff casts doubt on that).

    ## Calibration

    Categorize issues by actual severity. Not everything is Critical.
    Acknowledge what was done well before listing issues.

    ## Output format

    ### Strengths
    [What's well done? Be specific.]

    ### Issues

    #### Critical (Must Fix)
    [Bugs, security issues, data loss risks, broken functionality]

    #### Important (Should Fix)
    [Architecture problems, missing features, poor error handling, test gaps]

    #### Minor (Nice to Have)
    [Code style, optimization opportunities, documentation polish]

    For each issue: file:line reference, what's wrong, why it matters, how
    to fix (if not obvious).

    ### Assessment

    **Ready to merge?** [Yes | No | With fixes]

    **Reasoning:** [1-2 sentence technical assessment]

    ### Machine-readable verdict

    Your response must end with exactly one of these as the literal last
    line — nothing after it, no trailing punctuation or commentary:

    `BRANCH_REVIEW_VERDICT: CLEAN` (no Critical or Important issues), or
    `BRANCH_REVIEW_VERDICT: FINDINGS <K>` where `<K>` is the count of
    Critical + Important issues combined (Minor doesn't count).

    This line is parsed by code, not read by a human — get the count right
    and do not add anything after it.
```

**Placeholders:**
- `[TASK_LIST]` — every TASK-NNN that reached `done` this run, with title
  and file path (ralph already tracks this for its §7 summary table)
- `[EPIC_FILE]` — the epic file path if this run was scoped to one; omit for
  standalone/global runs
- `[BASE_SHA]` — `RUN_START_SHA`, captured at the top of this invocation
- `[HEAD_SHA]` — current HEAD

**Reviewer returns:** Strengths, Issues (Critical / Important / Minor),
Assessment, and a final `BRANCH_REVIEW_VERDICT: CLEAN|FINDINGS <K>` line —
the literal decision key both the Claude-side loop and the Pi-native driver
key their control flow off of, instead of fuzzy-matching the prose Assessment
(a naive substring check on "Critical" would also match the
`#### Critical (Must Fix)` heading even when that section is empty).
