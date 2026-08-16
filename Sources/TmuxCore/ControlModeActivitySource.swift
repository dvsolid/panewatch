import Foundation

/// The event-driven `ActivitySource` adapter (SPEC §3.2, ADR-0001): sources `lastOutputAt`
/// updates from tmux control-mode `%output` events, via a per-session pool of Control Clients,
/// instead of `PollingActivitySource`'s probe-and-hash. Covers both the steady-state happy path
/// (TASK-026 — spawn on first watched pane in a session, reap on last pane leaving, 250ms-per-pane
/// coalescing) and supervision (TASK-027 — reconnect a session whose client dies while others stay
/// alive; recognize every live client dying at once, e.g. a tmux server restart, as a distinct
/// condition and retry the whole pool on backoff rather than spinning).
///
/// Reports irrecoverable failure via `onFailure` (`FailableActivitySource`, TASK-029) with a
/// narrow signal: a session's attach attempt ends — either `ControlModeProcessLauncher.launch`
/// throwing synchronously, or the spawned process terminating — without ever having been
/// *confirmed*, i.e. proof (via `%end`/`ControlModeEvent.attachConfirmed`, or a real
/// `.output` event) that some attach genuinely succeeded, and this adapter has never
/// confirmed one before, for any session. Once any session has ever confirmed, this signal
/// never fires again: every later failure (a session's client dying, a reconnect attempt
/// failing) stays this class's own business, retried forever on the backoff below — never
/// `FallbackActivitySource`'s concern past that point. Live-verified against real tmux 3.6a:
/// `launch()` does *not* throw for a nonexistent-session attach (the process spawns fine and
/// tmux itself replies `%begin`/`<error text>`/`%error`/`%exit`, never reaching `%end`), so
/// the unconfirmed-termination half of this signal is load-bearing, not just the
/// launch-throws half the Slice names as its example. See `decisions.md` (TASK-029).
///
/// `@unchecked Sendable` like `PollingActivitySource`: each pooled process's `onLine`/`onTerminate`
/// fires on that process's own delivery thread while `setWatchedPanes` and the `onOutput` setter
/// may be called from another task, so `clientsBySession`, `watchedPaneIds`, `wantedSessions`,
/// `lastFiredAt`, `outputHandler`, `failureHandler`, `reconcilePending`, `backoffAttempt`,
/// `confirmedProcessIDs`, and `everConfirmed` — the only mutable stored state — are all read
/// and written exclusively under `lock`. `launcher`, `tmuxPath`, `clock`, `coalesceInterval`,
/// `scheduler`, and the backoff tuning constants are safe unguarded: all `let`-bound at `init`
/// and never reassigned.
public final class ControlModeActivitySource: FailableActivitySource, @unchecked Sendable {
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
    private var failureHandler: (() -> Void)?
    /// `true` from the moment a live client's unexpected termination is first observed until the
    /// deferred settle-tick actually runs `attemptReconnect()`. Guards against scheduling one
    /// settle-tick per terminating client: every client that dies within the same synchronous
    /// burst (e.g. a tmux server exit taking down every attached client at once) piles into the
    /// *same* pending tick, so the pool is reconciled once, as one batch — not once per session.
    /// That single settle-tick is what makes "every live client died at once" distinguishable
    /// from "one session's client died while others stayed alive": in the latter case,
    /// `attemptReconnect` finds that only one session died — the others' clients are still
    /// present in `clientsBySession`.
    private var reconcilePending = false
    /// Resets to 0 whenever any session's attach is confirmed (`confirmAttach`); increments once
    /// per failed attempt (synchronous launch throw, or an unconfirmed termination), driving
    /// `backoffDelay(forAttempt:)`. Deliberately *not* reset merely because `spawnClient`
    /// synchronously succeeded — that only proves the process launched, not that tmux actually
    /// accepted the attach (TASK-029: a launch can succeed and still die unconfirmed).
    private var backoffAttempt = 0
    /// `ObjectIdentifier`s of currently-live processes whose attach has been confirmed (TASK-029)
    /// — checked and removed at `handleTerminate` to decide that termination's shape, and removed
    /// at reap time too (`setWatchedPanes`) so a deallocated confirmed process's identifier can
    /// never be misread as confirmation for an unrelated later process reusing the same address.
    private var confirmedProcessIDs: Set<ObjectIdentifier> = []
    /// `true` once *any* session, ever, has confirmed its attach. Gates `onFailure`: this signal
    /// is only ever the "control mode may be structurally broken" report `FallbackActivitySource`
    /// needs — once any session has proven it works, every later failure is this class's own
    /// retry-forever business (SPEC §3.2's supervision requirements), never reported again.
    private var everConfirmed = false

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

    public var onFailure: (() -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return failureHandler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            failureHandler = newValue
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
                // TASK-029: drop this process's confirmation identity too — without this, a
                // deallocated confirmed process's `ObjectIdentifier` could be coincidentally
                // reused by a later, unrelated, genuinely-unconfirmed process and be misread as
                // proof it worked.
                confirmedProcessIDs.remove(ObjectIdentifier(process))
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
    /// picked up the next time any client's termination triggers a reconcile) — except for
    /// reporting `onFailure` (TASK-029) when this adapter has never confirmed any attach yet.
    @discardableResult
    private func spawnClient(for session: String) -> Bool {
        guard let process = try? launcher.launch(tmuxPath: tmuxPath, target: session) else {
            reportFailureIfNeverConfirmed()
            return false
        }
        process.onLine = { [weak self] line in
            self?.handle(line: line, process: process)
        }
        process.onTerminate = { [weak self] in
            self?.handleTerminate(session: session, process: process)
        }
        lock.lock()
        clientsBySession[session] = process
        lock.unlock()
        return true
    }

    /// Reports `onFailure` (TASK-029) for a failed attach attempt — a synchronous
    /// `launcher.launch` throw or an unconfirmed termination — but only while this adapter has
    /// never confirmed a working attach for any session. Fires every time this condition holds,
    /// not just once: `FallbackActivitySource`'s own switch is idempotent (no-op past the first
    /// firing), so repeated reports here are harmless, and gating on a local "already reported"
    /// flag would just be extra state for no behavioral difference.
    private func reportFailureIfNeverConfirmed() {
        let handler: (() -> Void)? = {
            lock.lock()
            defer { lock.unlock() }
            guard !everConfirmed else { return nil }
            return failureHandler
        }()
        handler?()
    }

    /// Records that `process`'s attach has been proven to work — via `%end`
    /// (`ControlModeEvent.attachConfirmed`, the reply to the implicit attach command) or any
    /// real `.output` event — and resets the backoff counter: this session (and, via
    /// `everConfirmed`, this adapter as a whole) has just demonstrated control mode genuinely
    /// works, so any earlier escalating delay no longer applies to what comes next.
    private func confirmAttach(for process: any ControlModeProcess) {
        lock.lock()
        confirmedProcessIDs.insert(ObjectIdentifier(process))
        everConfirmed = true
        backoffAttempt = 0
        lock.unlock()
    }

    /// Computes this attempt's backoff delay and advances the counter for the next one — shared
    /// by `attemptReconnect`'s synchronous-launch-failure branch and `handleTerminate`'s
    /// unconfirmed-termination branch, the two shapes a failed attach attempt can take.
    private func nextBackoffDelay() -> TimeInterval {
        lock.lock()
        let attempt = backoffAttempt
        backoffAttempt += 1
        lock.unlock()
        return min(reconnectInitialDelay * pow(reconnectBackoffFactor, Double(attempt)), reconnectMaxDelay)
    }

    /// Parses one control-mode line. `.attachConfirmed` records `process`'s attach as proven
    /// (TASK-029). For a watched pane's `.output` event (which also counts as proof the attach
    /// works — see `confirmAttach`), coalesces to at most one `onOutput` firing per
    /// `coalesceInterval`. Leading-edge coalescing (throttle, not trailing debounce): the first
    /// event in a window fires immediately — required so Blinking reflects the *first* byte of a
    /// burst, not the byte 250ms later — and subsequent events within `coalesceInterval` of that
    /// fire are dropped rather than deferred. A pane not in the current watched set is dropped
    /// here too: a Control Client attached to a session receives `%output` for every pane in
    /// that session, including ones nobody asked to watch (e.g. the user's own shell) — only
    /// watched panes may ever reach `onOutput`, matching `PollingActivitySource`, which can
    /// structurally only ever probe watched panes.
    private func handle(line: String, process: any ControlModeProcess) {
        switch ControlModeProtocolParser.parse(line) {
        case .attachConfirmed:
            confirmAttach(for: process)

        case .output(let paneId):
            confirmAttach(for: process)
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

        case .exit, .other:
            break
        }
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
    ///
    /// TASK-029: also determines whether `process` was ever confirmed (`%end`/`.output`) before
    /// dying. An unconfirmed termination — this attempt never proved the attach worked at all —
    /// reports `onFailure` (while `!everConfirmed`) and, when it's the termination that schedules
    /// the pending tick, paces that tick on the same backoff `attemptReconnect`'s synchronous
    /// failures use, instead of the original `delay: 0`: live-verified against real tmux (a
    /// nonexistent-session attach spawns fine and dies near-instantly, unconfirmed), a `delay: 0`
    /// retry here would otherwise respawn a real subprocess in an unbounded, zero-delay loop.
    private func handleTerminate(session: String, process: any ControlModeProcess) {
        lock.lock()
        guard clientsBySession[session] === process else {
            lock.unlock()
            return
        }
        clientsBySession.removeValue(forKey: session)
        let wasConfirmed = confirmedProcessIDs.remove(ObjectIdentifier(process)) != nil
        let shouldReportFailure = !wasConfirmed && !everConfirmed
        let failureHandlerToCall = shouldReportFailure ? failureHandler : nil
        let shouldSchedule = !reconcilePending
        if shouldSchedule {
            reconcilePending = true
        }
        lock.unlock()

        failureHandlerToCall?()

        guard shouldSchedule else { return }
        // A confirmed session's ordinary death keeps the original `delay: 0` — "once the current
        // synchronous burst of terminations has settled" (see `reconcilePending`'s doc comment),
        // not "reconnect instantly." An unconfirmed one is paced instead (see doc comment above).
        // `wasConfirmed` here is specifically *this* termination's — the one that won the race to
        // schedule the shared tick (the `shouldSchedule` guard above), which is exactly the one
        // whose delay choice matters: every other client dying in the same synchronous burst
        // piles into this same pending tick regardless of its own confirmation state.
        let delay = wasConfirmed ? 0 : nextBackoffDelay()
        scheduler.schedule(after: delay) { [weak self] in
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
    /// If every attempted session's `launch` call succeeds synchronously, nothing further is
    /// scheduled here — reconnection for *this pass* is complete, though TASK-029: that alone
    /// doesn't reset the backoff counter, since a successful `launch` doesn't yet prove tmux
    /// accepted the attach (a freshly-spawned, unconfirmed process dying is `handleTerminate`'s
    /// job to pace, not this method's — see its doc comment). If any attempted session's launch
    /// still fails synchronously (tmux still down, or never existed), the next attempt is paced
    /// via `scheduler` with a growing delay rather than retried immediately, so a
    /// persistently-failing launcher can never spin this into a tight loop (TASK-027 acceptance
    /// item 3).
    private func attemptReconnect() {
        let missing: Set<String> = {
            lock.lock()
            defer { lock.unlock() }
            return wantedSessions.subtracting(clientsBySession.keys)
        }()

        guard !missing.isEmpty else { return }

        let stillMissing = missing.filter { !spawnClient(for: $0) }

        guard !stillMissing.isEmpty else { return }

        scheduler.schedule(after: nextBackoffDelay()) { [weak self] in
            self?.attemptReconnect()
        }
    }
}
