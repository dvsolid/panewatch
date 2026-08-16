import Foundation

/// The event-driven `ActivitySource` adapter (SPEC §3.2, ADR-0001): sources `lastOutputAt`
/// updates from tmux control-mode `%output` events, via a per-session pool of Control Clients,
/// instead of `PollingActivitySource`'s probe-and-hash. Covers both the steady-state happy path
/// (TASK-026 — spawn on first watched pane in a session, reap on last pane leaving, 250ms-per-pane
/// coalescing) and supervision (TASK-027 — reconnect a session whose client dies while others stay
/// alive; recognize every live client dying at once, e.g. a tmux server restart, as a distinct
/// condition and retry the whole pool on backoff rather than spinning).
///
/// Fallback to `PollingActivitySource` on an attach failure that never recovers is
/// `FallbackActivitySource`'s job (TASK-028), not this adapter's — this class always keeps trying.
///
/// `@unchecked Sendable` like `PollingActivitySource`: each pooled process's `onLine`/`onTerminate`
/// fires on that process's own delivery thread while `setWatchedPanes` and the `onOutput` setter
/// may be called from another task, so `clientsBySession`, `watchedPaneIds`, `wantedSessions`,
/// `lastFiredAt`, `outputHandler`, `reconcilePending`, and `backoffAttempt` — the only mutable
/// stored state — are all read and written exclusively under `lock`. `launcher`, `tmuxPath`,
/// `clock`, `coalesceInterval`, `scheduler`, and the backoff tuning constants are safe unguarded:
/// all `let`-bound at `init` and never reassigned.
public final class ControlModeActivitySource: ActivitySource, @unchecked Sendable {
    private let launcher: any ControlModeProcessLauncher
    private let tmuxPath: String
    private let clock: @Sendable () -> Date
    private let coalesceInterval: TimeInterval
    private let scheduler: any ControlModeReconnectScheduler
    private let reconnectInitialDelay: TimeInterval
    private let reconnectBackoffFactor: Double
    private let reconnectMaxDelay: TimeInterval

    private let lock = NSLock()
    private var clientsBySession: [String: any ControlModeProcess] = [:]
    private var watchedPaneIds: Set<String> = []
    private var wantedSessions: Set<String> = []
    private var lastFiredAt: [String: Date] = [:]
    private var outputHandler: ((String, Date) -> Void)?
    /// `true` from the moment a live client's unexpected termination is first observed until the
    /// deferred settle-tick (scheduled at `delay: 0`) actually runs `attemptReconnect()`. Guards
    /// against scheduling one settle-tick per terminating client: every client that dies within
    /// the same synchronous burst (e.g. a tmux server exit taking down every attached client at
    /// once) piles into the *same* pending tick, so the pool is reconciled once, as one batch —
    /// not once per session. That single settle-tick is what makes "every live client died at
    /// once" distinguishable from "one session's client died while others stayed alive": in the
    /// latter case, `attemptReconnect` finds that only one session died — the others' clients
    /// are still present in `clientsBySession`.
    private var reconcilePending = false
    /// Resets to 0 whenever a reconnect attempt fully succeeds (every wanted session has a live
    /// client again); increments once per failed attempt, driving `backoffDelay(forAttempt:)`.
    private var backoffAttempt = 0

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
        coalesceInterval: TimeInterval = 0.25,
        scheduler: any ControlModeReconnectScheduler = DispatchControlModeReconnectScheduler(),
        reconnectInitialDelay: TimeInterval = 1.0,
        reconnectBackoffFactor: Double = 2.0,
        reconnectMaxDelay: TimeInterval = 30.0
    ) {
        self.launcher = launcher
        self.tmuxPath = tmuxPath
        self.clock = clock
        self.coalesceInterval = coalesceInterval
        self.scheduler = scheduler
        self.reconnectInitialDelay = reconnectInitialDelay
        self.reconnectBackoffFactor = reconnectBackoffFactor
        self.reconnectMaxDelay = reconnectMaxDelay
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
        self.wantedSessions = wantedSessions
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
        // (a fake process in tests does, and so does the live process once the underlying exit
        // lands), which must never re-enter while `lock` is held. `clientsBySession` no longer
        // holds this session's entry by the time `terminate()` runs, so `handleTerminate`'s
        // identity guard rejects the resulting callback as a reap, not a crash.
        for process in processesToTerminate {
            process.terminate()
        }

        for session in sessionsToSpawn {
            spawnClient(for: session)
        }
    }

    /// Attempts to launch and register a Control Client for `session`, wiring both `onLine` and
    /// `onTerminate`. Returns whether the launch succeeded. Launch failures are silently dropped
    /// here — a session missing from `clientsBySession` after this call simply stays a candidate
    /// for the next `attemptReconnect` pass (or, for the initial `setWatchedPanes` spawn, is
    /// picked up the next time any client's termination triggers a reconcile).
    @discardableResult
    private func spawnClient(for session: String) -> Bool {
        guard let process = try? launcher.launch(tmuxPath: tmuxPath, target: session) else {
            return false
        }
        process.onLine = { [weak self] line in
            self?.handle(line: line)
        }
        process.onTerminate = { [weak self] in
            self?.handleTerminate(session: session, process: process)
        }
        lock.lock()
        clientsBySession[session] = process
        lock.unlock()
        return true
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

    /// Fires when a pooled Control Client exits, for any reason — natural (session killed, tmux
    /// server exited) or via our own `terminate()` during a reap. `session`/`process` are the
    /// values captured at spawn time (`spawnClient`), so this always identifies which client is
    /// reporting, even if `clientsBySession[session]` has since moved on to a different process.
    ///
    /// Identity-guarded against reaps (TASK-027 acceptance item 5): `setWatchedPanes` removes a
    /// session's entry from `clientsBySession` *before* calling `terminate()` on it, so by the
    /// time this fires for a deliberately-reaped session, `clientsBySession[session]` is either
    /// absent or already holds a different (freshly reconnected) process — either way, `===`
    /// fails and this is a no-op. Only a client that is still the one currently on record for its
    /// session reaches the reconcile scheduling below.
    private func handleTerminate(session: String, process: any ControlModeProcess) {
        lock.lock()
        guard clientsBySession[session] === process else {
            lock.unlock()
            return
        }
        clientsBySession.removeValue(forKey: session)
        let shouldSchedule = !reconcilePending
        if shouldSchedule {
            reconcilePending = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        // `delay: 0`: not "reconnect instantly," but "once the current synchronous burst of
        // terminations has settled" — see `reconcilePending`'s doc comment. Every other client
        // that dies before this fires piles into the same pending batch.
        scheduler.schedule(after: 0) { [weak self] in
            self?.beginReconcile()
        }
    }

    private func beginReconcile() {
        lock.lock()
        reconcilePending = false
        lock.unlock()
        attemptReconnect()
    }

    /// One reconnect pass: spawns a fresh Control Client for every currently-wanted session that
    /// doesn't have one. Scoped automatically by whatever `clientsBySession` looks like right
    /// now — if only one session's client died, every other session is still present and only
    /// the dead one gets attempted; if every client died at once, all of them are missing and all
    /// get attempted together in this same pass. That's the whole distinction TASK-027 acceptance
    /// items 1 and 2 ask for: it falls out of diffing against live state, not a separate
    /// single-vs-pool-wide branch.
    ///
    /// If every attempted session succeeds, the backoff counter resets and nothing further is
    /// scheduled — reconnection is complete. If any attempted session's launch still fails (tmux
    /// still down), the next attempt is paced via `scheduler` with a growing delay rather than
    /// retried immediately, so a persistently-failing launcher can never spin this into a tight
    /// loop (TASK-027 acceptance item 3).
    private func attemptReconnect() {
        let missing: Set<String> = {
            lock.lock()
            defer { lock.unlock() }
            return wantedSessions.subtracting(clientsBySession.keys)
        }()

        guard !missing.isEmpty else {
            resetBackoff()
            return
        }

        let stillMissing = missing.filter { !spawnClient(for: $0) }

        guard !stillMissing.isEmpty else {
            resetBackoff()
            return
        }

        let attempt: Int = {
            lock.lock()
            defer { lock.unlock() }
            let current = backoffAttempt
            backoffAttempt += 1
            return current
        }()
        let delay = min(
            reconnectInitialDelay * pow(reconnectBackoffFactor, Double(attempt)),
            reconnectMaxDelay
        )
        scheduler.schedule(after: delay) { [weak self] in
            self?.attemptReconnect()
        }
    }

    private func resetBackoff() {
        lock.lock()
        backoffAttempt = 0
        lock.unlock()
    }
}
