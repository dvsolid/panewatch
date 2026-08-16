# tmuxer-mac

Native macOS menu bar app that monitors AI coding agent tmux sessions and shows a vertical
floating status bar. Design lives in [SPEC.md](SPEC.md) — read it before implementing anything;
it records which behaviours were verified against a live tmux server and which are assumptions.

## Test commands

The `qtc-dev-*` skills read this table. `execute-task`, `simplify`, and `verify` must all pass
the **same literal string** to `append_review.py gate` — the gate cache is keyed on exact
command text, so a paraphrase silently misses the cache and re-runs the whole suite.

| Purpose | Command |
|---|---|
| **Full suite (the gate command)** | `swift test` |
| Focused (one suite, during red→green) | `swift test --filter <Suite>.<Case>` |
| Build with warnings as errors | `swift build -Xswiftc -warnings-as-errors` |

## Layout

```
Package.swift
Sources/
  TmuxCore/      pure logic — discovery, parsing, agent detection, ActivitySource
  TmuxerApp/     AppKit/SwiftUI shell
Tests/
  TmuxCoreTests/
```

`TmuxCore` must stay free of AppKit so it tests headlessly. Anything needing a window,
`NSStatusItem`, or the main run loop belongs in `TmuxerApp`.

## Toolchain

- Swift 6.0.3, strict concurrency. Target platform `.macOS(.v14)`.
- **No full Xcode on this machine** — Command Line Tools only, so `xcodebuild` is unavailable.
  SPM is the only build path; don't propose `.xcodeproj` or XCUITest workflows.
- Python 3 is required by the `qtc-dev-*` vault scripts.

## tmux

- Never invoke bare `tmux` — the user's interactive `tmux` is a zsh plugin alias that fails to
  resolve non-interactively. Resolve the binary explicitly (`/opt/homebrew/bin/tmux` here).
- Tests must not depend on live tmux sessions. Shell out through an injectable command runner
  so the real binary can be faked; skip explicitly when tmux is absent.
- `pane_id` (`%51`) is the only stable identity for a pane. Never key on `session:window.pane`.

## Repo conventions

- No remote. Ralph's whole-branch review uses `RUN_START_SHA...HEAD`, never `origin/main`.
- `docs/project/` is the qtc-dev vault: gitignored operational state, never staged.
- Stage source explicitly (`git add -- Sources/ Tests/ Package.swift`). Never `git add -A`.
