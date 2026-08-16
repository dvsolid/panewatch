import Foundation

/// The event-driven `ActivitySource` adapter (SPEC §3.2, ADR-0001): sources `lastOutputAt`
/// updates from tmux control-mode `%output` events, via a per-session pool of Control Clients,
/// instead of `PollingActivitySource`'s probe-and-hash. Covers only the steady-state happy path
/// — spawn on first watched pane in a session, reap on last pane leaving, 250ms-per-pane
/// coalescing. Reconnect-on-`%exit` and full-server-restart backoff are TASK-027, layered on top
/// of this pool bookkeeping.
///
/// `@unchecked Sendable` like `PollingActivitySource`: each pooled process's `onLine` fires on
/// that process's own delivery thread while `setWatchedPanes` and the `onOutput` setter may be
/// called from another task, so `clientsBySession`, `watchedPaneIds`, `lastFiredAt`, and
/// `outputHandler` — the only mutable stored state — are all read and written exclusively under
/// `lock`. `launcher`, `tmuxPath`, `clock`, and `coalesceInterval` are safe unguarded: all
/// `let`-bound at `init` and never reassigned.
public final class ControlModeActivitySource: ActivitySource, @unchecked Sendable {
    private let launcher: any ControlModeProcessLauncher
    private let tmuxPath: String
    private let clock: @Sendable () -> Date
    private let coalesceInterval: TimeInterval

    private let lock = NSLock()
    private var clientsBySession: [String: any ControlModeProcess] = [:]
    private var watchedPaneIds: Set<String> = []
    private var lastFiredAt: [String: Date] = [:]
    private var outputHandler: ((String, Date) -> Void)?

    public var onOutput: ((String, Date) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return outputHandler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            outputHandler = newValue
        }
    }

    public init(
        launcher: any ControlModeProcessLauncher,
        tmuxPath: String,
        clock: @escaping @Sendable () -> Date = { Date() },
        coalesceInterval: TimeInterval = 0.25
    ) {
        self.launcher = launcher
        self.tmuxPath = tmuxPath
        self.clock = clock
        self.coalesceInterval = coalesceInterval
    }

    /// Diffs the wanted session set (derived from `panes`' values, ADR-0004) against the pool's
    /// current session set: spawns one Control Client for each newly-watched session, reaps
    /// (terminates) each session that no longer has any watched pane. A session with ≥1 watched
    /// pane both before and after this call is untouched — no re-spawn.
    public func setWatchedPanes(_ panes: [String: String]) {
        let wantedSessions = Set(panes.values)
        let wantedPaneIds = Set(panes.keys)

        lock.lock()
        watchedPaneIds = wantedPaneIds
        // Drop coalescing state for panes no longer watched, mirroring
        // `PollingActivitySource.setWatchedPanes`'s stale-hash eviction: a pane that leaves and
        // later rejoins the watched set should fire on its first post-rejoin `%output`, not stay
        // suppressed by a leftover fire time from before it was dropped.
        for staleId in lastFiredAt.keys where !wantedPaneIds.contains(staleId) {
            lastFiredAt.removeValue(forKey: staleId)
        }
        let currentSessions = Set(clientsBySession.keys)
        let sessionsToSpawn = wantedSessions.subtracting(currentSessions)
        let sessionsToReap = currentSessions.subtracting(wantedSessions)
        var processesToTerminate: [any ControlModeProcess] = []
        for session in sessionsToReap {
            if let process = clientsBySession.removeValue(forKey: session) {
                processesToTerminate.append(process)
            }
        }
        lock.unlock()

        // Terminated outside the lock: `terminate()` may synchronously invoke `onTerminate`
        // (a fake process in tests does), which must never re-enter while `lock` is held.
        for process in processesToTerminate {
            process.terminate()
        }

        for session in sessionsToSpawn {
            // Launch failures are silently dropped here: falling back to `PollingActivitySource`
            // on a failed attach is `FallbackActivitySource`'s job (TASK-028), not this adapter's.
            guard let process = try? launcher.launch(tmuxPath: tmuxPath, target: session) else {
                continue
            }
            process.onLine = { [weak self] line in
                self?.handle(line: line)
            }
            lock.lock()
            clientsBySession[session] = process
            lock.unlock()
        }
    }

    /// Parses one control-mode line and, for a watched pane's `.output` event, coalesces to at
    /// most one `onOutput` firing per `coalesceInterval`. Leading-edge coalescing (throttle, not
    /// trailing debounce): the first event in a window fires immediately — required so Blinking
    /// reflects the *first* byte of a burst, not the byte 250ms later — and subsequent events
    /// within `coalesceInterval` of that fire are dropped rather than deferred. A pane not in the
    /// current watched set is dropped here too: a Control Client attached to a session receives
    /// `%output` for every pane in that session, including ones nobody asked to watch (e.g. the
    /// user's own shell) — only watched panes may ever reach `onOutput`, matching
    /// `PollingActivitySource`, which can structurally only ever probe watched panes.
    private func handle(line: String) {
        guard case .output(let paneId) = ControlModeProtocolParser.parse(line) else { return }

        let now = clock()
        let handler: ((String, Date) -> Void)? = {
            lock.lock()
            defer { lock.unlock() }
            guard watchedPaneIds.contains(paneId) else { return nil }
            if let last = lastFiredAt[paneId], now.timeIntervalSince(last) < coalesceInterval {
                return nil
            }
            lastFiredAt[paneId] = now
            return outputHandler
        }()

        handler?(paneId, now)
    }
}
