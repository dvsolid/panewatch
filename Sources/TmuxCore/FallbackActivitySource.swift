import Foundation

/// The generic failure signal `FallbackActivitySource` composes over (architect module reference:
/// `features/2026-08-15-control-mode-activity-source.md` `## Architecture`, `FallbackActivitySource`
/// section — "the exact failure signal ... is an implementation-phase decision, not fixed here").
/// An `ActivitySource` adapter that can irrecoverably fail (e.g. `ControlModeActivitySource`, wired
/// in TASK-029) adopts this refinement and calls `onFailure?()` once it decides its own primary role
/// is over. Adapters that structurally can't fail (e.g. `PollingActivitySource`) never need to
/// conform — only `FallbackActivitySource`'s `primary` parameter requires it, which makes "this
/// primary can report failure" a compile-time property of the composition instead of a runtime
/// downcast that silently no-ops if forgotten.
public protocol FailableActivitySource: ActivitySource {
    var onFailure: (() -> Void)? { get set }
}

/// Generic composing `ActivitySource` (SPEC §3.2 companion, ADR reference: feature architecture's
/// `FallbackActivitySource` section): routes `setWatchedPanes`/`onOutput` through `primary` until it
/// signals `onFailure`, then switches to `secondary` and stays there — no flapping back. Consumers
/// above this seam (`StatusBarEngine`) hold only `any ActivitySource` and never know a fallback is
/// composed underneath.
///
/// `@unchecked Sendable`: `usingSecondary`, `lastPanes`, and `outputHandler` are the only mutable
/// stored state, read and written exclusively under `lock` — `primary.onFailure` may fire on
/// whatever thread the adapter's own failure detection runs on, concurrently with a caller's
/// `setWatchedPanes`/`onOutput` access. `primary` and `secondary` are `let`-bound at `init` and
/// never reassigned; mutating their `onOutput`/`onFailure` closures happens once, in `init`.
public final class FallbackActivitySource: ActivitySource, @unchecked Sendable {
    private let primary: any FailableActivitySource
    private let secondary: any ActivitySource

    private let lock = NSLock()
    private var usingSecondary = false
    private var lastPanes: [String: String] = [:]
    private var outputHandler: ((String, Date) -> Void)?

    public var onOutput: ((String, Date) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return outputHandler
        }
        set {
            lock.lock()
            outputHandler = newValue
            lock.unlock()
        }
    }

    public init(primary: any FailableActivitySource, secondary: any ActivitySource) {
        self.primary = primary
        self.secondary = secondary

        // Wired once, up front, rather than lazily inside the `onOutput` setter: whichever route
        // is active at the moment either fake fires is decided by `usingSecondary`, not by
        // whether the consumer has assigned `onOutput` yet.
        primary.onOutput = { [weak self] paneId, at in
            guard let self, !self.isUsingSecondary else { return }
            self.onOutput?(paneId, at)
        }
        secondary.onOutput = { [weak self] paneId, at in
            guard let self, self.isUsingSecondary else { return }
            self.onOutput?(paneId, at)
        }
        primary.onFailure = { [weak self] in self?.switchToSecondary() }
    }

    private var isUsingSecondary: Bool {
        lock.lock()
        defer { lock.unlock() }
        return usingSecondary
    }

    public func setWatchedPanes(_ panes: [String: String]) {
        lock.lock()
        lastPanes = panes
        let secondaryActive = usingSecondary
        lock.unlock()

        if secondaryActive {
            secondary.setWatchedPanes(panes)
        } else {
            primary.setWatchedPanes(panes)
        }
    }

    /// Latches to `secondary` permanently (no flapping): a second `onFailure` firing — or one that
    /// arrives after an earlier switch already happened — is a no-op, matching acceptance item 3.
    /// Replays the most recently requested pane map to `secondary` on the way in, outside the lock:
    /// `secondary.setWatchedPanes` must never run while `lock` is held, since `onFailure` may arrive
    /// on a foreign thread mid-call, mirroring `ControlModeActivitySource.setWatchedPanes`'s same
    /// convention.
    ///
    /// Also tells `primary` to stop watching everything (`setWatchedPanes([:])`), outside the
    /// lock for the same reason. Without this, an abandoned `ControlModeActivitySource` primary
    /// keeps `wantedSessions` frozen at its last pre-switch value: every post-switch call routes
    /// to `secondary` only (`setWatchedPanes` above), so nothing ever tells `primary` its watched
    /// set shrank, and its own supervision (TASK-027's reconnect-on-termination) keeps respawning
    /// real `tmux -C attach` subprocesses against sessions this source no longer reports on,
    /// forever. Reaping via an empty pane map reuses `primary`'s own teardown path — no new
    /// `ActivitySource` member needed.
    private func switchToSecondary() {
        lock.lock()
        guard !usingSecondary else {
            lock.unlock()
            return
        }
        usingSecondary = true
        let panes = lastPanes
        lock.unlock()

        secondary.setWatchedPanes(panes)
        primary.setWatchedPanes([:])
    }
}
