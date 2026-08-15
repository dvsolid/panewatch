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
        // Same bug class TASK-014's review caught on `NSTrackingArea.owner` (also `weak`):
        // without this wiring surviving past init, `processTerminated` would never reach a
        // live delegate and acceptance items 4/5 would be silently dead despite a green build.
        assert(terminalView.processDelegate != nil, "PreviewClient.terminalView.processDelegate was not retained")
    }

    /// Prepares the grouped session and spawns the read-only attach as `terminalView`'s child
    /// process. Synchronous failures (tmux binary missing, or any `PreviewClientLifecycle`
    /// step failing — e.g. the pane is already gone) report `.unavailable` immediately and
    /// never call `startProcess` at all.
    func start(paneID: String) {
        spawnedAt = Date()
        guard FileManager.default.isExecutableFile(atPath: tmuxPath) else {
            reportOutcome(.unavailable)
            return
        }
        do {
            let groupName = try lifecycle.prepareGroupSession(paneID: paneID)
            self.groupName = groupName
            let invocation = PreviewClientInvocation.attachInvocation(tmuxPath: tmuxPath, groupName: groupName)
            terminalView.startProcess(executable: invocation.executable, args: invocation.arguments)
        } catch {
            reportOutcome(.unavailable)
        }
    }

    /// Idempotent. Terminates the child process (if still running) and tears down the grouped
    /// session — after this returns, `tmux list-clients` no longer lists the Preview Client
    /// (acceptance item 2).
    func stop() {
        didReportOutcome = true
        onOutcome = nil
        terminalView.terminate()
        if let groupName {
            lifecycle.teardownGroupSession(groupName)
        }
        groupName = nil
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
