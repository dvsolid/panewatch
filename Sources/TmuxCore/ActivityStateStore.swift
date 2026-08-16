import Foundation

/// Owns the `lastOutputAt` map keyed by `pane_id`; derives each pane's Activity Phase as a
/// pure function of a given time — SPEC §1's four-phase boundaries, with zero timer or
/// subprocess machinery here (feature spec § Architecture, this task's Test seam).
///
/// A class, not a struct: `StatusBarEngine` holds one instance across repeated scans, and
/// `ActivitySource.onOutput` writes into it from whatever context the source calls back on —
/// lock-protected like `AgentDetector`'s `DescendantWalkCache`, for the same reason.
public final class ActivityStateStore: @unchecked Sendable {
    private let blinkWindow: TimeInterval
    private let readyWindow: TimeInterval
    private let fadeWindow: TimeInterval
    private var lastOutputAt: [String: Date] = [:]
    /// Per-pane deadline before which `recordOutput` is ignored — see `muteOutput(paneId:until:)`.
    private var mutedUntil: [String: Date] = [:]
    private let lock = NSLock()

    public init(
        blinkWindow: TimeInterval = TmuxCore.defaultBlinkWindow,
        readyWindow: TimeInterval = TmuxCore.defaultReadyWindow,
        fadeWindow: TimeInterval = TmuxCore.defaultFadeWindow
    ) {
        self.blinkWindow = blinkWindow
        self.readyWindow = readyWindow
        self.fadeWindow = fadeWindow
    }

    public func recordOutput(paneId: String, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        if let deadline = mutedUntil[paneId], date < deadline {
            return
        }
        lastOutputAt[paneId] = date
    }

    /// Suppresses `recordOutput` for `paneId` up to (not including) `until` — extends rather
    /// than shortens an existing mute, so two overlapping mute calls (e.g. a very brief hover
    /// whose zoom-in and zoom-out land close together) merge into one window instead of the
    /// second call cutting the first short.
    ///
    /// Exists for `PreviewClientLifecycle` (TmuxCore): the Hover Preview Popup's `resize-pane
    /// -Z` zoom is a real, shared window-level tmux operation — verified live that it resizes
    /// the previewed pane, which its foreground program (always a full-screen TUI for an Agent
    /// Pane) redraws in response, producing a genuinely different `capture-pane` sample. Left
    /// unmuted, `PollingActivitySource` correctly reports that as new output and flips the Tile
    /// active on every hover, even though nothing was typed. This is the one seam that lets a
    /// known, self-inflicted repaint be told apart from real activity without weakening
    /// `PollingActivitySource`'s own change detection for every other case.
    public func muteOutput(paneId: String, until: Date) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = mutedUntil[paneId], existing >= until {
            return
        }
        mutedUntil[paneId] = until
    }

    /// Seeds `lastOutputAt` for a pane this store has never recorded, without disturbing one it
    /// already has — `StatusBarEngine.reconcile` calls this for every discovered pane on every
    /// pass, using tmux's own `#{window_activity}` (`AgentPane.windowActivityAt`) as the value.
    /// That timestamp is tracked by the tmux server, not this app, so it survives an app
    /// relaunch: the very first `reconcile()` after a restart seeds each pane's true last-output
    /// time instead of reading it as `.idle` from a cold, empty map. A pane this store already
    /// has a record for — whether from a prior `recordOutput` or a prior `seedIfAbsent` — is left
    /// untouched, since `ActivitySource.onOutput` is the more precise source once it starts
    /// firing.
    public func seedIfAbsent(paneId: String, at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        if lastOutputAt[paneId] == nil {
            lastOutputAt[paneId] = date
        }
    }

    /// A pane with no recorded output has no `idleDuration` to compute. In practice this only
    /// happens for a pane `StatusBarEngine.reconcile` hasn't run `seedIfAbsent` for yet (e.g. a
    /// caller driving this store directly, bypassing `reconcile`) — defaults to `.idle`, the
    /// safer read for a pane of genuinely unknown recency.
    public func phase(for paneId: String, now: Date) -> ActivityPhase {
        lock.lock()
        let lastOutput = lastOutputAt[paneId]
        lock.unlock()
        guard let lastOutput else { return .idle }

        let idleDuration = now.timeIntervalSince(lastOutput)
        switch idleDuration {
        case ..<blinkWindow:
            return .blinking
        case ..<readyWindow:
            return .ready
        case ..<fadeWindow:
            return .fading(colorFraction: (idleDuration - readyWindow) / (fadeWindow - readyWindow))
        default:
            return .idle
        }
    }
}

/// The minimal seam `PreviewClientLifecycle` depends on to mute its own zoom-induced repaint —
/// `muteOutput(paneId:until:)` alone, rather than the whole of `ActivityStateStore`, so a caller
/// that only needs to suppress activity doesn't also gain the ability to read or reset phases.
public protocol ActivityMuter: Sendable {
    func muteOutput(paneId: String, until: Date)
}

extension ActivityStateStore: ActivityMuter {}
