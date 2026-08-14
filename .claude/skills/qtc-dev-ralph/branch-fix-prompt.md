# Whole-Branch Fix Prompt Template

Used by qtc-dev-ralph §6.2 step 4 — one fixer dispatch for the *complete*
Critical/Important findings list from the whole-branch review, never one
fixer per finding (per-finding fixers each rebuild context and re-run tests
for no benefit; superpowers found a real session's final-review fix wave
cost more than all its tasks combined when done that way).

```
Subagent (qtc-dev-ralph-branch-fixer):
  description: "Fix wave: whole-branch review findings"
  prompt: |
    A whole-branch review of this Ralph run found the findings below. Fix
    every one of them in this single pass.

    ## Findings to fix

    [FINDINGS — the complete Critical + Important list from the review,
    copied verbatim, one per bullet, each with its file:line reference]

    ## Scope

    Fix exactly these findings. Do not refactor unrelated code, do not
    address the review's Minor/Nice-to-have notes unless fixing a Critical
    or Important finding requires it incidentally.

    ## Tests

    After fixing, re-run only the tests covering the files you touched — not
    the full suite. If a finding has no covering test, add one that would
    have caught it.

    ## Do not stage or commit

    Leave the working tree as your edits leave it. The caller stages and
    commits after you return.

    ## Output format

    For each finding, in order:

    - **[finding one-liner]** — what changed (file:line), and the test
      command + result that confirms it's fixed.

    If you disagree a finding is real, say so explicitly with your reasoning
    instead of silently skipping it — the re-review that follows treats an
    unaddressed finding as NOT ADDRESSED either way.
```

**Placeholders:**
- `[FINDINGS]` — the review's Critical + Important issues, verbatim
