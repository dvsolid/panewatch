import AppKit
import SwiftTerm
import TmuxCore

/// The Hover Preview Popup's live terminal, backed by a real Preview Client (glossary "Preview
/// Client") — a short-lived, read-only tmux client attached to a grouped session (see
/// `PreviewClientLifecycle`/`PreviewClientInvocation`, TmuxCore) so hovering a Tile never
/// disturbs the pane's own source session (TASK-015's `## Implementation` records the
/// `[REQ CHANGE]` that made this necessary — a direct pane-targeted attach was verified live
/// to retarget the source session's shared current window on every hover).
///
/// `HoverPreviewController` creates one fresh instance per `open(paneID:tileView:)` rather
/// than reusing one across panes/opens — a new hover must never show the previous pane's
/// stale scrollback while its own attach is still spinning up.
@MainActor
final class PreviewClient: NSObject, LocalProcessTerminalViewDelegate {
    enum Outcome {
        /// Prepare or spawn failed — acceptance item 5, "tmux unreachable" being the named
        /// example. The caller shows the inline "preview unavailable" state.
        case unavailable
        /// The attach process exited on its own after already being live. The caller closes
        /// the popup gracefully.
        ///
        /// **This does not reliably fire for "the pane/window closed underneath the popup"**
        /// (acceptance item 4's main scenario) — verified live that a grouped session (see
        /// `PreviewClientLifecycle`) outlives the window it was created to view whenever the
        /// source session has other windows: it just falls back to showing whichever window
        /// remains, silently. It also outlives the *source session itself* being killed, since
        /// the group's own attachment is an independent reference keeping the shared window
        /// alive. `.closed` in practice only covers the narrower case of the whole tmux server
        /// exiting or the grouped session being killed out from under the client some other
        /// way. Item 4's real coverage for the common "pane/window closed" case is
        /// `HoverPreviewController.tileSetWillChange(remaining:)`, which already closes the
        /// popup once discovery's periodic rescan (SPEC §2, ~30s) no longer reports the pane —
        /// see this task's `## Implementation` notes for the empirical findings and the
        /// resulting latency trade-off.
        case closed
    }

    /// `processTerminated` firing inside this window of `start(paneID:)` is treated as
    /// "the spawn itself failed" (`.unavailable`) rather than "something that was already
    /// showing live content went away" (`.closed`) — tmux's own exit codes don't distinguish
    /// the two (a killed grouped session and a bad attach target both exit non-zero), so
    /// elapsed time since spawn is the discriminator instead.
    private static let spawnFailureGraceWindow: TimeInterval = 1.0

    let terminalView: LocalProcessTerminalView = ReadOnlyLocalProcessTerminalView(frame: .zero)

    /// Fires exactly once per instance, either from `start(paneID:)` failing synchronously or
    /// from `processTerminated` later. `nil`s itself out after firing (`didReportOutcome`) so
    /// a `processTerminated` that arrives after an explicit `stop()` never double-reports —
    /// `stop()` is a normal close, not an outcome the controller needs telling about again.
    var onOutcome: ((Outcome) -> Void)?

    private let lifecycle: PreviewClientLifecycle
    private let tmuxPath: String
    private var groupSession: PreviewClientLifecycle.GroupSession?
    private var spawnedAt: Date?
    private var didReportOutcome = false

    /// The same Nerd Font family a real terminal/shell prompt on this machine uses, on user
    /// request, so glyphs it draws (Powerline separators, git-branch icons, an agent's own
    /// status-line icons) render as the intended glyph in the preview instead of a tofu box.
    /// `Mono`, not the plain `JetBrainsMonoNL Nerd Font` family: the plain variant leaves icon
    /// glyphs double-width, which breaks monospace cell alignment in a terminal render — `Mono`
    /// patches them to single-width cells specifically so terminals can use it safely.
    private static let preferredFontName = "JetBrainsMonoNL Nerd Font Mono"
    /// A bit larger than the previous fixed 10pt, on user request.
    private static let fontSize: CGFloat = 11

    /// `NSFont(name:size:)` returns `nil` rather than silently substituting anything when the
    /// named family isn't installed (unlike, say, an `NSAttributedString`'s automatic font
    /// substitution) — fall back explicitly so a machine without this Nerd Font installed still
    /// gets a working monospaced terminal font instead of this call site producing no font at
    /// all.
    private static func makeTerminalFont() -> NSFont {
        NSFont(name: preferredFontName, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    private static func ansiColor(_ hex: UInt32) -> Color {
        Color(
            red8: UInt16((hex >> 16) & 0xFF),
            green8: UInt16((hex >> 8) & 0xFF),
            blue8: UInt16(hex & 0xFF)
        )
    }

    /// On user request: raising contrast only for `nativeForegroundColor` above would barely
    /// change anything, since almost every glyph a preview shows carries its own ANSI color
    /// from the agent CLI rather than that one unstyled default — so this overrides all 16 ANSI
    /// slots, keeping each hue recognizable (red stays red, a CLI's diff/warning colors still
    /// read as diff/warning colors) while pushing every one to a legible lightness against
    /// `nativeBackgroundColor`. Index 8 ("bright black") matters most: it's the slot most CLIs
    /// and markdown renderers pick for secondary/dim text, which is exactly what read as washed
    /// out before this.
    private static let highContrastAnsiPalette: [Color] = [
        ansiColor(0x1A1A1E), // 0  black
        ansiColor(0xFF6B6B), // 1  red
        ansiColor(0x59D499), // 2  green
        ansiColor(0xFFD166), // 3  yellow
        ansiColor(0x5AA9FF), // 4  blue
        ansiColor(0xC792EA), // 5  magenta
        ansiColor(0x4FD6E0), // 6  cyan
        ansiColor(0xC7CCD6), // 7  white
        ansiColor(0xA6ACB8), // 8  bright black (the usual dim/comment slot)
        ansiColor(0xFF8787), // 9  bright red
        ansiColor(0x6EE7A8), // 10 bright green
        ansiColor(0xFFDB85), // 11 bright yellow
        ansiColor(0x7FBBFF), // 12 bright blue
        ansiColor(0xD7A8F0), // 13 bright magenta
        ansiColor(0x7BE6EE), // 14 bright cyan
        ansiColor(0xF5F5F7)  // 15 bright white
    ]

    init(
        gateway: any TmuxGateway = ProcessTmuxGateway(),
        tmuxPath: String = TmuxCore.defaultTmuxPath,
        activityMuter: (any ActivityMuter)? = nil
    ) {
        self.lifecycle = PreviewClientLifecycle(gateway: gateway, activityMuter: activityMuter)
        self.tmuxPath = tmuxPath
        super.init()
        terminalView.processDelegate = self
        // SwiftTerm's own `Terminal.silentLog` defaults to false in DEBUG builds, so its
        // internal parser `print()`s an "Info: Unhandled DEC Private Mode ..." line to stdout
        // for every escape sequence it doesn't implement (e.g. shell-integration codes like
        // 2031/7727) — harmless, but floods the log on every hover once real pane output with
        // those sequences arrives.
        terminalView.terminal.silentLog = true
        // See `makeTerminalFont()`'s doc comment for the font choice and fallback.
        terminalView.font = Self.makeTerminalFont()
        // On user request: SwiftTerm's only two defaults here were a flat-black background and
        // one unstyled foreground (~4.9:1 against it, barely WCAG AA) — everything else visible
        // in a preview (comments, prose, dim text) is whatever ANSI color the agent CLI already
        // picked, which read far lower-contrast than that. Fixing the ladder, not just the
        // headline text, means overriding the full 16-color ANSI palette too
        // (`installColors(_:)`), not only background/foreground — the trade-off, accepted here,
        // is that a CLI's own color choices (its reds, its "dim" comments) no longer come
        // through verbatim; every pane now renders through this one fixed scheme instead.
        // `nativeBackgroundColor`/`nativeForegroundColor`, not the popup's own material/layer:
        // `LocalProcessTerminalView` paints its own opaque background every frame, over whatever
        // sits behind it in the view hierarchy.
        terminalView.nativeBackgroundColor = NSColor(calibratedRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0D / 255, alpha: 1.0)
        terminalView.nativeForegroundColor = NSColor(calibratedRed: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1.0)
        terminalView.installColors(Self.highContrastAnsiPalette)
        // Same bug class TASK-014's review caught on `NSTrackingArea.owner` (also `weak`):
        // without this wiring surviving past init, `processTerminated` would never reach a
        // live delegate and acceptance items 4/5 would be silently dead despite a green build.
        assert(terminalView.processDelegate != nil, "PreviewClient.terminalView.processDelegate was not retained")
    }

    /// Prepares the grouped session off the main actor — `PreviewClientLifecycle
    /// .prepareGroupSession` is five sequential blocking `Process` spawns (whole-branch review
    /// finding: this used to run synchronously on the main actor, freezing the UI behind every
    /// hover-open) — then hops back to spawn the read-only attach as `terminalView`'s child
    /// process. The tmux-binary-missing check stays a cheap synchronous stat call; every other
    /// failure (any `PreviewClientLifecycle` step failing — e.g. the pane is already gone)
    /// reports `.unavailable` once the detached prepare comes back and never calls
    /// `startProcess` at all.
    func start(paneID: String) {
        spawnedAt = Date()
        guard FileManager.default.isExecutableFile(atPath: tmuxPath) else {
            reportOutcome(.unavailable)
            return
        }
        let lifecycle = lifecycle
        let tmuxPath = tmuxPath
        // The outer task stays on the main actor throughout (`@MainActor`, `weak self`) — only
        // the inner `Task.detached` runs off it, and that inner closure captures no `self` at
        // all (just the Sendable `lifecycle`/`paneID`), so there's never a point where a
        // non-Sendable `self` needs to cross an isolation boundary.
        Task { @MainActor [weak self] in
            do {
                let groupSession = try await Task.detached {
                    try lifecycle.prepareGroupSession(paneID: paneID)
                }.value
                guard let self, !self.didReportOutcome else {
                    // `stop()` already fired (popup closed while prepare was still in-flight)
                    // or an outcome already reported some other way — clean up the group
                    // session that just got created rather than leaking it or racing a
                    // terminal view that's already been torn down. Detached, not run inline:
                    // `teardownGroupSession` is a blocking `kill-session` spawn that must never
                    // run on the main actor (see `stop()`'s doc comment).
                    Task.detached { lifecycle.teardownGroupSession(groupSession) }
                    return
                }
                self.groupSession = groupSession
                self.sizeTerminal(toWindowRows: groupSession.windowHeight)
                let invocation = PreviewClientInvocation.attachInvocation(tmuxPath: tmuxPath, groupName: groupSession.groupName)
                self.terminalView.startProcess(executable: invocation.executable, args: invocation.arguments)
            } catch {
                self?.reportOutcome(.unavailable)
            }
        }
    }

    /// Grows `terminalView`'s frame taller than the popup's visible box, if needed, until its
    /// own row count is at least `windowRows` — the font never changes, so every preview reads
    /// at the same size regardless of which pane it's showing. Must run before `startProcess`:
    /// `LocalProcessTerminalView.getWindowSize()` reads the *current* `terminal.rows`/`.cols` to
    /// size the spawned pty, so the grown row count has to already be in place by the time the
    /// attach spawns, not applied as a resize afterward.
    ///
    /// Without this, a real window taller than the popup's fixed pixel budget
    /// (`HoverPopupPlacement.size`) at this terminal's font leaves `-f ignore-size`
    /// (`PreviewClientInvocation.attachInvocation`'s doc comment) showing this client a
    /// viewport tmux positions around wherever the source pane's cursor currently sits — not
    /// the window's top or bottom. Verified live against a real, zoomed Pi pane: the source
    /// program's cursor sat well above the client's own row budget, so every row it painted
    /// landed on a row number the client's buffer didn't have — the preview came back entirely
    /// blank, not merely missing its bottom edge. Matching the client's row count to the real
    /// window's removes the mismatch that makes tmux need to pick a sub-viewport at all.
    ///
    /// The grown frame keeps `origin = (0, 0)` within `HoverPreviewPopup`'s `innerContent`,
    /// which clips its subviews (`HoverPreviewPopup.init`'s doc comment) — SwiftTerm draws row 0
    /// (the *oldest* visible content) near the top of the view's own bounds and the last row
    /// (the newest content — the prompt) near its bottom, in AppKit's unflipped coordinate
    /// system (verified against `AppleTerminalView`'s `lineOrigin = frame.height - lineOffset`).
    /// So growing the frame upward from a fixed `y = 0` and letting `innerContent` clip
    /// whatever now extends above it keeps the *bottom* of the real window in view — the most
    /// relevant part, and what a live glance actually needs — rather than an arbitrary,
    /// tmux-chosen slice.
    ///
    /// An earlier version of this fix shrank the font instead of growing the frame, to
    /// guarantee full coverage within the popup's fixed box. Live user feedback on a real,
    /// very tall window (240x53) found the result close to unreadable, and inconsistent from
    /// preview to preview since each window needed a different amount of shrinking — growing
    /// the frame and clipping keeps one fixed, legible font for every preview instead.
    ///
    /// Deliberately grows rows only, not columns — a window wider than the client just clips
    /// the right edge of each visible line (same as any narrower-than-content terminal), which
    /// degrades far more gracefully than a whole row going missing, and nobody has actually
    /// reported the horizontal case.
    ///
    /// Not `private`: `PreviewClientSizeTerminalTests` (`PaneWatchAppTests`) calls this directly
    /// against a frame sized exactly like `HoverPreviewPopup`'s `innerContent` — the one path
    /// this module can't verify by running the app (this session has no native-GUI-automation
    /// tool to actually hover a Tile), so exercising the real SwiftTerm geometry call chain
    /// (`terminalView.frame =` → `processSizeChange(newSize:)` → `terminal.cols`/`.rows`) head-on
    /// is the closest substitute for watching it happen live.
    func sizeTerminal(toWindowRows windowRows: Int) {
        guard windowRows > 0 else { return }
        let visibleRows = terminalView.terminal.rows
        guard visibleRows < windowRows, visibleRows > 0 else { return }

        let visibleFrame = terminalView.frame
        var candidateHeight = visibleFrame.height * CGFloat(windowRows) / CGFloat(visibleRows)

        // The analytic first guess can still fall a cell short once `processSizeChange`'s
        // pixel-to-cell rounding kicks in — grow in small steps rather than solving it exactly.
        for _ in 0..<8 {
            terminalView.frame = CGRect(x: 0, y: 0, width: visibleFrame.width, height: candidateHeight)
            if terminalView.terminal.rows >= windowRows { return }
            candidateHeight *= 1.1
        }
    }

    /// Idempotent. Terminates the child process (if still running), clears local state, and
    /// returns the pending grouped-session teardown (a no-op closure if no group was ever
    /// created) instead of running it inline — `PreviewClientLifecycle.teardownGroupSession` is
    /// a blocking `kill-session` spawn that must never run on the main actor (whole-branch
    /// review finding), but some callers (`HoverPreviewController.tileDoubleClicked`) need that
    /// spawn to *complete* before their own next tmux call runs, a guarantee only the caller
    /// can enforce by awaiting the closure itself. After the returned closure runs, `tmux
    /// list-clients` no longer lists the Preview Client (acceptance item 2).
    @discardableResult
    func stop() -> @Sendable () -> Void {
        didReportOutcome = true
        onOutcome = nil
        terminalView.terminate()
        guard let groupSession else { return {} }
        self.groupSession = nil
        let lifecycle = lifecycle
        return { lifecycle.teardownGroupSession(groupSession) }
    }

    /// Fully synchronous teardown, including the blocking `kill-session` spawn — for the one
    /// call site with no room to hop off the main actor at all: `AppDelegate
    /// .applicationWillTerminate`, where a detached task's `kill-session` would never get to
    /// run before the process exits (whole-branch review finding: that's exactly how a
    /// `panewatch-preview-*` session survives app quit indefinitely today). A brief main-actor
    /// block during quit is an acceptable trade for not leaking the session.
    func stopSynchronously() {
        stop()()
    }

    private func reportOutcome(_ outcome: Outcome) {
        guard !didReportOutcome else { return }
        didReportOutcome = true
        onOutcome?(outcome)
    }

    // MARK: - LocalProcessTerminalViewDelegate
    // SwiftTerm predates Swift 6 concurrency checking, so these requirements aren't
    // MainActor-isolated on the protocol side even though `LocalProcess` always dispatches
    // them on the main queue at runtime (its own doc comment). `nonisolated` + hopping back
    // via `Task { @MainActor in ... }` mirrors the pattern `HoverPreviewController` already
    // uses for its (similarly non-isolated) `Timer` callbacks.

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            guard let spawnedAt = self.spawnedAt else { return }
            let elapsed = Date().timeIntervalSince(spawnedAt)
            self.reportOutcome(elapsed < Self.spawnFailureGraceWindow ? .unavailable : .closed)
        }
    }
}

/// The load-bearing layer of the terminal render's read-only guarantee. Before TASK-032,
/// `HoverPreviewPopup.canBecomeKey == false` also blocked `keyDown` from ever reaching this (or
/// any) view in the popup — TASK-032 (ADR-0006) needs the popup's new Preview Input text field
/// to become key-focusable, so that blanket window-level block is gone (see that type's doc
/// comment) and this override is now doing the real work: dropping every byte `TerminalView`
/// tries to `send`, whether it arrived via `keyDown` or an input path that doesn't require key
/// focus at all, e.g. mouse-reporting sequences a terminal app can emit for clicks/scrolling.
/// tmux's own `-r` (read-only) flag on the underlying attach is a second line of defense if
/// this were ever bypassed regardless.
private final class ReadOnlyLocalProcessTerminalView: LocalProcessTerminalView {
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Deliberately empty — see this type's doc comment.
    }

    /// SwiftTerm's `TerminalView` unconditionally installs an `NSScroller` pinned to its own
    /// trailing/top/bottom anchors (`MacTerminalView.setupScroller`), and — because that scroller
    /// is a bare control, not one an `NSScrollView` manages — nothing ever auto-hides it. It
    /// draws a permanent ~12pt light slot down the full height of the preview that can't be
    /// dragged and scrolls nothing (`scroller.isEnabled = false`), which is exactly the artifact
    /// the user reported: "a light grey bar that looks like a scrollbar except there's no way to
    /// scroll." Live-measured on this machine at 2x: the bar spans the popup's `innerContent`
    /// bounds to the pixel (y 96→1224, right edge flush at its trailing edge), which is that
    /// scroller's geometry and nothing else's.
    ///
    /// SwiftTerm keeps the scroller `private` with no visibility API — but its own
    /// `reservedScrollerWidth` is written as `scroller?.isHidden == true ? 0 : scrollerWidth`,
    /// so `isHidden` is the supported lever: hiding it also hands the reserved width back to the
    /// terminal instead of leaving a dead gutter. Removing it from the view tree would do
    /// neither (`isHidden` would stay `false`) and would break SwiftTerm's own constraints.
    ///
    /// Applied here rather than once at init because this runs on every layout pass, so it
    /// survives anything upstream that recreates or re-shows the scroller. The `where` guard
    /// makes it a no-op after the first pass — hiding it changes `reservedScrollerWidth`, which
    /// feeds back into layout, and re-setting `isHidden` unconditionally would keep dirtying it.
    private func hideScroller() {
        for case let scroller as NSScroller in subviews where !scroller.isHidden {
            scroller.isHidden = true
        }
    }

    override func layout() {
        super.layout()
        hideScroller()
    }

    /// `layout()` alone would leave the scroller visible until the first layout pass — and the
    /// terminal's column count is derived from `reservedScrollerWidth` before then
    /// (`PreviewClient.sizeTerminal(toWindowRows:)` runs ahead of `startProcess`). Hiding it as
    /// soon as the view is installed keeps the pty sized against the final width.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        hideScroller()
    }
}
