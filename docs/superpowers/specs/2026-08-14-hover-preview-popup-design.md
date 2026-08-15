# Hover Preview Popup — Design

**Date:** 2026-08-14
**Status:** Approved, not yet decomposed into tasks.

## Goal

Hovering a Tile in the Status Bar opens a popup, stuck to the tile, showing a live
**read-only** preview of that pane's terminal output. The popup contains a **Switch**
button that performs the real focus-or-open behavior SPEC.md §4 already specifies but
which has never been implemented — no click handling exists on `TileCardView` today.

This design also corrects a factual error in SPEC.md §Phase 2: the permission needed to
select a specific window in another app via AppleScript is **Automation (TCC)**, granted
per source app the first time it scripts a given target app — not **Accessibility**.
`NSRunningApplication.activate()` alone was investigated and rejected: it's known to
silently fail to foreground apps on macOS Sonoma+, and even when it works it can only
foreground an app, not select one window among several — that requires either
Accessibility (`AXUIElement`, unavailable to sandboxed apps) or each target app's own
AppleScript dictionary. Ghostty (1.3+), iTerm2, and Terminal.app all expose the latter,
including per-session `tty` properties to match against `client_tty`.

## Non-goals

- Interactive typing into the popup's mini terminal (read-only preview only).
- Migrating the preview off a spawned tmux client onto the future Phase 2 control-mode
  `%output` stream (SPEC §3.2) — that infrastructure doesn't exist yet. This design is
  self-contained and ships without it; a later swap is possible but out of scope now.
- Multi-monitor placement beyond basic on-screen clamping.

## Module split

Follows the existing `TmuxCore` (pure, headless-testable) / `TmuxerApp` (AppKit,
manually verified) boundary — same pattern as `DescendantProcessInspector` (pure ps-walk
logic) feeding `FloatingPanel`/`TileCardView` (AppKit).

- **`TmuxCore`**: resolving `client_tty` → owning terminal app (pid, bundle id), and
  picking which per-app AppleScript strategy applies. Pure functions over a process
  table, unit-tested with fakes — same style as existing `DescendantProcessInspector`
  tests.
- **`TmuxerApp`**: hover detection (`NSTrackingArea`), the popup window itself, SwiftTerm
  embedding, spawning/killing the preview's tmux client, and actually invoking
  `osascript`. Manually verified only, consistent with `FloatingPanel`'s existing
  precedent (its own doc comment already calls it "the one manually-verified piece").

## Hover popup UX

- `NSTrackingArea` on each `TileCardView`. ~350ms dwell before opening (avoids flicker on
  mouse-through). ~250ms grace before closing — the mouse must leave both the tile *and*
  the popup, so moving into the popup to click Switch doesn't collapse it.
- Popup opens to the **left** of the tile — the panel is pinned to the screen's right
  edge (`FloatingPanel.frame`), so there's no room to open rightward. Vertically centered
  on the tile, clamped to stay fully on-screen.
- Only one popup is live at a time. Hovering a new tile tears down the previous popup's
  preview client before spawning the next — mirrors how a single tooltip behaves.
- Fixed size for v1, ~420×260pt. Not resizable.

## Mini terminal (SwiftTerm)

- New SPM dependency: **SwiftTerm**, added to `Package.swift` on the `TmuxerApp` target
  only (never `TmuxCore` — see CLAUDE.md).
- `LocalProcessTerminalView`'s child process:
  `tmux attach -r -f read-only,ignore-size -t <pane_id>`
  - `pane_id` (`%51`) is used directly as the target, per SPEC §3.4's existing guidance
    to avoid the dotted-window-name ambiguity.
  - `-r` (read-only client) plus `-f read-only,ignore-size` matches the flags SPEC §3.2
    already validated for monitoring clients: it can't resize the user's real session
    under `window-size=smallest`, and tmux itself rejects any stray input from this
    client as defense in depth even though the UI never forwards keystrokes.
- Lifecycle: spawn on popup open, terminate the child process on popup close (detaches
  the client). If the process exits on its own (pane or window closed underneath it),
  the popup closes gracefully instead of freezing on stale content. If the spawn fails
  outright (tmux binary missing, server gone), show a small inline "preview unavailable"
  state instead of a blank SwiftTerm view.

## Switch button (SPEC §4, first implementation)

1. Resolve `client_tty` → owning process → owning app, reusing
   `DescendantProcessInspector`'s ps-walk approach (pure, testable in `TmuxCore`).
2. If an attached client and a supported owning app (Ghostty, iTerm2, or Terminal.app)
   are found: run that app's own AppleScript dictionary to find the window/tab whose
   session `tty` matches `client_tty`, select it, and activate the app. The first time a
   given app is scripted, macOS shows its standard Automation permission prompt.
3. If there's no attached client, the owning app isn't one of the three supported apps,
   or Automation permission is denied: fall back to opening a new terminal via
   `tmux attach` (SPEC §4 path 2) — the same "Focus existing → Open new → Fallback"
   priority SPEC already specifies.
4. Clicking Switch closes the popup and tears down its preview client first.

## Error handling / edge cases

- Pane disappears while the popup is open → preview client's process exits → popup
  closes.
- `tmux attach` spawn fails immediately → inline "preview unavailable" state, popup stays
  open (so hovering doesn't feel broken) but shows no terminal.
- `client_tty` unresolvable to any of the three supported apps → Switch falls straight to
  open-new, no AppleScript attempted.
- Automation permission denied → Switch falls back to open-new rather than failing
  silently.

## Testing

- `TmuxCore`: tty → owning-app resolution and per-app strategy selection, unit-tested
  against fake process tables (same style as existing `DescendantProcessInspector`
  tests). AppleScript *script selection* (which strategy applies) is testable as pure
  data; actual `osascript` execution is not.
- `TmuxerApp`: hover trigger, SwiftTerm embedding, real `osascript` invocation — manually
  verified only, per existing `FloatingPanel` precedent.

## Open follow-ups (not blocking this design)

- Correct SPEC.md §Phase 2's "requires Accessibility" note to "requires Automation
  (TCC)" once this ships.
- Consider migrating the preview client onto the Phase 2 control-mode stream once that
  infrastructure exists, to avoid a second spawned tmux client per popup open.
