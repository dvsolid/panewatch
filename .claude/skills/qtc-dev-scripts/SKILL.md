---
name: qtc-dev-scripts
description: Use when any qtc-dev skill needs to mutate task/epic state, allocate IDs, or validate the vault. Run these scripts instead of hand-editing frontmatter prose.
---

# qtc-dev-scripts

Machine-readable helpers for vault state mutation. Skills are policy; these scripts are the mechanism.

All scripts auto-locate `docs/project/` by walking up from CWD. Run from the project root.

## Scripts

| Script | Purpose | Usage |
|---|---|---|
| `allocate_id.py` | Increment counter and print new ID | `python .claude/skills/qtc-dev-scripts/allocate_id.py <epic\|task\|adr>` |
| `list_ready.py` | List ready tasks with satisfied deps | `python .claude/skills/qtc-dev-scripts/list_ready.py [EPIC-NNN]` |
| `mark_status.py` | Set status field on any task/epic file | `python .claude/skills/qtc-dev-scripts/mark_status.py <path> <status>` |
| `append_review.py` | Run the test gate; record review outcome; flip status | `python .claude/skills/qtc-dev-scripts/append_review.py <gate\|pass\|fail\|blocked> <path> ["<notes>"]` |
| `prepend_decision.py` | Prepend a real **decision** to `memory/decisions.md` | `python .claude/skills/qtc-dev-scripts/prepend_decision.py "- YYYY-MM-DD [TAG] text"` |
| `prepend_log.py` | Prepend a **lifecycle breadcrumb** to `memory/pipeline-log.md` | `python .claude/skills/qtc-dev-scripts/prepend_log.py "- YYYY-MM-DD [TAG] text"` |
| `normalize_links.py` | Convert wikilinks in depends_on to plain IDs | `python .claude/skills/qtc-dev-scripts/normalize_links.py [--dry-run]` |
| `validate_vault.py` | Full structural sanity check | `python .claude/skills/qtc-dev-scripts/validate_vault.py` |

## Valid statuses

`ready` | `in-progress` | `done` | `blocked-by-human`

## Notes

- `allocate_id.py` is not file-locked; only one caller should run it at a time.
- `normalize_links.py` is idempotent — safe to re-run on already-normalized files.
- `validate_vault.py` exits 0 on clean, 1 on errors (warnings do not fail).
- `append_review.py fail` auto-escalates to `blocked-by-human` on the second failure (`review_failures ≥ 2`).
- `append_review.py gate <path> "<command>"` runs the command from repo root and prints `VERDICT: GREEN|RED` (exit 0/1). Any shell command works — exit 0 is GREEN, non-zero is RED.
- `append_review.py pass <path> "<summary>" "<command>"` re-runs the command as a guard and **refuses** (non-zero exit, no status change) unless GREEN — a task cannot be marked done while the suite fails.
- `append_review.py blocked <path> "<reason>"` escalates to `blocked-by-human` without consuming a review-failure strike. Use for infrastructure failures the retry ladder cannot fix.
- **Two memory logs, kept separate:** `prepend_log.py` → `pipeline-log.md` (automated lifecycle breadcrumbs: BRAINSTORM/ARCHITECT/DECOMPOSE/EXECUTE/VERIFY/RALPH); `prepend_decision.py` → `decisions.md` (real decisions only: ADR/REQ CHANGE/EXPERIMENT/SPIKE/BUG FIX/INFRA/INTEGRATION). This keeps the decision record from drowning under hundreds of breadcrumbs. Both prepend under a file lock.
