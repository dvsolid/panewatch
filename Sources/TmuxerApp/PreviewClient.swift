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
    private var groupName: String?
    private var spawnedAt: Date?
    private var didReportOutcome = false

    init(gateway: any TmuxGateway = ProcessTmuxGateway(), tmuxPath: String = TmuxCore.defaultTmuxPath) {
        self.lifecycle = PreviewClientLifecycle(gateway: gateway)
        self.tmuxPath = tmuxPath
        super.init()
        terminalView.processDelegate = self
        // SwiftTerm's own `Terminal.silentLog` defaults to false in DEBUG builds, so its
        // internal parser `print()`s an "Info: Unhandled DEC Private Mode ..." line to stdout
        // for every escape sequence it doesn't implement (e.g. shell-integration codes like
        // 2031/7727) — harmless, but floods the log on every hover once real pane output with
        // those sequences arrives.
        terminalView.terminal.silentLog = true
        // Smaller than SwiftTerm's default (the system font size, ~13pt) so the popup's fixed
        // frame (`HoverPopupPlacement.size`) fits more rows/cols of real pane content.
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
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
                let groupName = try await Task.detached {
                    try lifecycle.prepareGroupSession(paneID: paneID)
                }.value
                guard let self, !self.didReportOutcome else {
                    // `stop()` already fired (popup closed while prepare was still in-flight)
                    // or an outcome already reported some other way — clean up the group
                    // session that just got created rather than leaking it or racing a
                    // terminal view that's already been torn down.
                    lifecycle.teardownGroupSession(groupName)
                    return
                }
                self.groupName = groupName
                let invocation = PreviewClientInvocation.attachInvocation(tmuxPath: tmuxPath, groupName: groupName)
                self.terminalView.startProcess(executable: invocation.executable, args: invocation.arguments)
            } catch {
                self?.reportOutcome(.unavailable)
            }
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
        guard let groupName else { return {} }
        self.groupName = nil
        let lifecycle = lifecycle
        return { lifecycle.teardownGroupSession(groupName) }
    }

    /// Fully synchronous teardown, including the blocking `kill-session` spawn — for the one
    /// call site with no room to hop off the main actor at all: `AppDelegate
    /// .applicationWillTerminate`, where a detached task's `kill-session` would never get to
    /// run before the process exits (whole-branch review finding: that's exactly how a
    /// `tmuxer-preview-*` session survives app quit indefinitely today). A brief main-actor
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

/// Structural half of the read-only guarantee below the AppKit-window level — the other half
/// is `HoverPreviewPopup.canBecomeKey == false`, which already prevents `keyDown` from ever
/// reaching this view (see that type's doc comment). Overriding `send` closes the remaining
/// gap: input paths that don't require key focus, e.g. mouse-reporting sequences a terminal
/// app can emit for clicks/scrolling inside it. tmux's own `-r` (read-only) flag on the
/// underlying attach is a second line of defense if this were ever bypassed regardless.
private final class ReadOnlyLocalProcessTerminalView: LocalProcessTerminalView {
    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        // Deliberately empty — see this type's doc comment.
    }
}
