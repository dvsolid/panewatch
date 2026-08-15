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
        lastOutputAt[paneId] = date
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
