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

    /// A pane with no recorded output (never watched, or watched but silent since launch) has
    /// no `idleDuration` to compute — SPEC's `lastOutputAt[paneId] ?? processStart` fallback
    /// isn't available at this seam. Defaults to `.idle`: an unknown pane reading as freshly
    /// grey is the safer failure than reading as freshly active.
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
