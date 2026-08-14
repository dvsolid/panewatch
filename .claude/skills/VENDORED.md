# Vendored qtc-dev skills

These skills are a **copy**, not a symlink. They have diverged from upstream to target a
Swift/SPM macOS app instead of a Python/TypeScript web app.

| | |
|---|---|
| **Upstream** | `https://git.ringcentral.com/dmitryv/qtc-dev-skills` |
| **Local clone** | `/Users/dmitryv/Work/Projects/billing/qtc-dev-skills` |
| **Base SHA** | `c54daa7` ("Fix gate-cache correctness and drop hardcoded project refs") |
| **Vendored** | 2026-08-13 |

The `qtc-dev-*` prefix is kept deliberately. It reads oddly in a repo unrelated to
Quote-to-Cash, but it appears in ~20 hardcoded script paths and in every agent name, and
keeping it means upstream fixes cherry-pick cleanly. Renaming is a single `sed` pass whenever
that trade stops being worth it.

## Not vendored

| Skill | Why |
|---|---|
| `qtc-dev-e2e` | Playwright/browser-specific. A macOS menu bar app has no browser; the analogue would be XCUITest, which needs full Xcode (unavailable here — see below). |
| `qtc-dev-side-note` | Hardcoded `npm test` / `pytest` commands, and its value is a quick off-pipeline path we don't need yet. |

`agents/qtc-dev-ralph-e2e-gate.md` is likewise not vendored, since §6.3 of ralph is gone.

## What diverged

| File | Change |
|---|---|
| `qtc-dev-ralph/SKILL.md` | `backend/ frontend/ e2e/` → `Sources/ Tests/ Package.swift` (5 sites). **Deleted §6.3 Post-loop e2e gate** and every cross-reference to it; §6.2 whole-branch review is now the final gate. |
| `qtc-dev-ralph/LOOP-MECHANICS.md` | Dropped the `RUN_START_SHA` vs `origin/main` comparison — the latter no longer exists. |
| `qtc-dev-ralph/branch-re-review-prompt.md` | Dropped an appeal to the e2e gate's `blocked-by-human` precedent. |
| `qtc-dev-verify/SKILL.md` | Replaced the browser tiers (e2e seam gate, `frontend/public/` asset check) with Swift tiers: warnings-as-errors build, Swift 6 `Sendable`/actor-isolation review, and a rule that tests must not depend on live tmux. |
| `qtc-dev-simplify/SKILL.md` | Collapsed the two-stack gate (backend + frontend) into one `swift test` call. |
| `qtc-dev-execute-task/SKILL.md` | Focused-test example `pytest tests/test_foo.py` → `swift test --filter`. |
| `qtc-dev-scripts/*`, `qtc-dev-setup/SKILL.md` | Dropped `E2E` from the lifecycle-tag vocabulary (4 sites). Otherwise unmodified. |
| `qtc-dev-sanity-doctor/SKILL.md` | Module-drift checks (rules 14–15) looked up `*_snake_case*.py` under `backend/app/`. Retargeted to `<TypeName>.swift` under `Sources/`; added `Source`/`Detector` to the matched type-name suffixes. Missed on the first pass — flagged by re-running the divergence grep after the initial edit round, worth noting since the same grep is verification step 5 below. |
| `agents/qtc-dev-ralph-executor.md` | "across backend/frontend/DB layers" → "across the app's layers" (descriptive prose only, no functional path). |

`qtc-dev-brainstorm`, `-architect`, `-decompose` are **byte-identical to upstream** — they
carry no stack assumptions.

## Deliberate non-changes

- **`origin/main`** — ralph's whole-branch review uses `RUN_START_SHA...HEAD`, captured locally.
  The only `origin/main` reference lived inside the deleted §6.3, so this repo's lack of a
  remote is a non-issue. Don't reintroduce a remote-relative base.
- **`qtc-gate.json`** — the upstream setup skill lists it under idempotency rules but never
  creates it, and nothing reads it. `append_review.py gate` takes its command as an argument.
  Dangling reference upstream; harmless.
- **`sanity-doctor/test_doctor.py`** — a pytest suite for the Python vault tooling. It is not
  project code and `swift test` does not cover it. Correct as-is.

## Verified at vendoring time

- Gate mechanics: `append_review.py gate` → `VERDICT: GREEN` (exit 0) / `VERDICT: RED` (exit 1);
  `pass` refuses on RED with "Cannot mark done."
- `REPO_ROOT` (`parents[3]`) resolves correctly at this vendored depth.
- `validate_vault.py` passes; `allocate_id.py` increments; SessionStart hook emits valid JSON.

## Resolved: SwiftPM toolchain mismatch (2026-08-13)

At vendoring time, `swift test` could not run on this machine — not a project problem.
Command Line Tools 16.2 had shipped a mismatched SwiftPM: `PackageDescription.swiftmodule`
(Dec 23 2024) was newer than `libPackageDescription.dylib` (Dec 6 2024), so the `Package.init`
symbol the compiler emitted didn't exist at link time. Every `Package.swift` failed, including
a bare three-line one; confirmed against tools-versions 6.0, 5.10, and 5.9 — no manifest change
worked around it.

**Fixed by reinstalling Command Line Tools** (`sudo rm -rf /Library/Developer/CommandLineTools
&& sudo xcode-select --install`). Re-verified after: `swift test` builds and passes, and the
real gate command now returns `VERDICT: GREEN` end-to-end through `append_review.py gate`.
