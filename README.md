# PaneWatch

[![Tests](https://github.com/dvsolid/panewatch/actions/workflows/tests.yml/badge.svg)](https://github.com/dvsolid/panewatch/actions/workflows/tests.yml)

A native macOS menu bar app that watches your tmux sessions and shows which AI coding agents
(Claude Code, Codex, Pi, OMP, etc.) are running, what they're doing, and whether they need your
attention — in a small floating status bar you can glance at from any Space. OMP (Oh My Pi)
brands its tmux title with the same `π` prefix as Pi, so the two are told apart by the live
`omp` vs `pi` process under the pane.

## Requirements

- macOS 14 (Sonoma) or later
- [tmux](https://github.com/tmux/tmux) (installed via Homebrew or otherwise)
- Swift 6 toolchain (Xcode 16+ Command Line Tools) to build from source

## Build & run from source

There is no prebuilt/signed binary yet — build it yourself with the Swift Package Manager:

```sh
git clone https://github.com/dvsolid/panewatch.git
cd panewatch
swift build -c release
.build/release/PaneWatchApp
```

Or run it directly during development:

```sh
swift run PaneWatchApp
```

## How it works

PaneWatch polls tmux for panes running a known coding agent, classifies each pane's activity
into one of four phases (blinking, ready, fading, idle), and renders one tile per pane in a
floating vertical status bar. See [SPEC.md](SPEC.md) for the full design — the detection
heuristics, timing model, and which behaviors have been verified against a live tmux server
versus which are still assumptions.

## License

MIT — see [LICENSE](LICENSE).
