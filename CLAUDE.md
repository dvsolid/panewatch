# PaneWatch

Native macOS menu bar app that monitors AI coding agent tmux sessions and shows a vertical
floating status bar. Design lives in [SPEC.md](SPEC.md) — read it before implementing anything;
it records which behaviours were verified against a live tmux server and which are assumptions.

## Test commands

| Purpose | Command |
|---|---|
| Full suite | `swift test` |
| Focused (one suite, during red→green) | `swift test --filter <Suite>.<Case>` |
| Build with warnings as errors | `swift build -Xswiftc -warnings-as-errors` |
| Lint | `docker run --rm -v "$PWD:/work" -w /work ghcr.io/realm/swiftlint:0.65.0 lint --strict` |

Lint runs via Docker rather than a local SwiftLint install — see Toolchain below.

## Layout

```
Package.swift
Sources/
  TmuxCore/      pure logic — discovery, parsing, agent detection, ActivitySource
  PaneWatchApp/  AppKit/SwiftUI shell
Tests/
  TmuxCoreTests/
```

`TmuxCore` must stay free of AppKit so it tests headlessly. Anything needing a window,
`NSStatusItem`, or the main run loop belongs in `PaneWatchApp`.

## Toolchain

- Swift 6.0.3, strict concurrency. Target platform `.macOS(.v14)`.
- Building with Command Line Tools only (no full Xcode)? `xcodebuild` is unavailable — SPM is
  the only build path; don't propose `.xcodeproj` or XCUITest workflows.
- SwiftLint via Homebrew can fail to run on a Command Line Tools-only install: it dlopens
  `sourcekitdInProc.framework` at startup, and that load fails outside a full Xcode.app (the
  framework itself is present and loadable — this is specifically SourceKitten's
  `@rpath`-dependent loader). Run it via the Docker image instead (see the Lint row above); CI
  does the same, on a separate `ubuntu-latest` job, since GitHub's hosted macOS runners can't run
  Docker at all.

## tmux

- Never invoke bare `tmux` — an interactive shell's `tmux` can be aliased (e.g. by a zsh plugin)
  in a way that doesn't resolve non-interactively. `TmuxCore.resolveTmuxPath()` picks the binary
  from a fixed candidate list instead of a `PATH` search, so the alias is never in play.
- Tests must not depend on live tmux sessions. Shell out through an injectable command runner
  so the real binary can be faked; skip explicitly when tmux is absent.
- `pane_id` (`%51`) is the only stable identity for a pane. Never key on `session:window.pane`.

## Repo conventions

- Stage source explicitly (`git add -- Sources/ Tests/ Package.swift`) rather than `git add -A`.
