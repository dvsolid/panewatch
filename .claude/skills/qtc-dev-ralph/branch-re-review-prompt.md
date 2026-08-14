# Whole-Branch Scoped Re-Review Prompt Template

Used by qtc-dev-ralph §6.2 step 6, after the fix wave commits. Verifies each
finding was addressed and checks the fix diff for new breakage — not a
fresh whole-branch review, that already happened. Adapted from superpowers'
`subagent-driven-development/re-review-prompt.md`.

```
Subagent (qtc-dev-ralph-branch-re-reviewer):
  description: "Re-review: whole-branch fix wave"
  prompt: |
    A whole-branch review produced findings; a fix subagent attempted to
    address all of them in one pass. Your job is to verdict each finding and
    inspect the fix diff — nothing else.

    ## Findings under verification

    [FINDINGS — the same Critical + Important list the fixer was given]

    ## The fix

    **Fix base:** [FIX_BASE_SHA] (the HEAD the whole-branch review saw)
    **Head:** [HEAD_SHA] (current HEAD, after the fix commit)

    ```bash
    git diff --stat [FIX_BASE_SHA]..[HEAD_SHA]
    git diff [FIX_BASE_SHA]..[HEAD_SHA]
    ```

    Your review is read-only on this checkout. Do not mutate the working
    tree, the index, HEAD, or branch state in any way.

    ## Scope

    Verdict every finding in the list above. Inspect the fix diff for new
    problems the fix itself introduced. Do not re-review code the fix didn't
    touch — that's out of scope for this pass.

    ## Output format

    Begin directly with the first finding's verdict — no preamble.

    ### Finding verdicts

    For each finding, in order:
    - **[finding one-liner]** — ADDRESSED | NOT ADDRESSED, with file:line
      evidence. "Attempted" is not addressed: the specific defect must no
      longer exist.

    ### New breakage in the fix diff

    Anything the fix itself broke or introduced, with severity
    (Critical/Important/Minor) and file:line. "None" if clean.

    ### Verdict

    **Fix round:** [All findings addressed, no new Critical/Important
    breakage | Findings remain open] — list the open ones.

    ### Machine-readable verdict

    Your response must end with exactly one of these as the literal last
    line — nothing after it:

    `BRANCH_REVIEW_FIX_VERDICT: CLEAN` (every finding ADDRESSED, no new
    Critical/Important breakage), or `BRANCH_REVIEW_FIX_VERDICT: RESIDUAL
    <short summary>` (anything NOT ADDRESSED, or new Critical/Important
    breakage — name it briefly in the summary).

    This line is parsed by code, not read by a human.
```

**Placeholders:**
- `[FINDINGS]` — the Critical + Important findings the fixer was given
- `[FIX_BASE_SHA]` — the HEAD the whole-branch review saw
- `[HEAD_SHA]` — current HEAD, after the fix commit

**Re-reviewer returns:** per-finding verdicts (ADDRESSED / NOT ADDRESSED),
new breakage in the fix diff, a round verdict, and a final
`BRANCH_REVIEW_FIX_VERDICT: CLEAN|RESIDUAL <summary>` line — the literal
decision key. Note: no second fix wave — residual Critical/Important
findings escalate to the user via `branch_review: blocked-by-human`
(§6.2 step 7) rather than triggering another automated fix attempt.
