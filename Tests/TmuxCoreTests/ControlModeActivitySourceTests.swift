import Foundation
import Testing
@testable import TmuxCore

/// Fakes `ControlModeProcessLauncher`/`ControlModeProcess` (no real `tmux -C attach`
/// subprocess) so `ControlModeActivitySource`'s pool/coalescing logic is exercised at the
/// `ActivitySource` seam without depending on a live tmux server — mirrors
/// `PollingActivitySourceTests.FakeTmuxGateway`'s role for `PollingActivitySource`.
private final class FakeControlModeProcess: ControlModeProcess, @unchecked Sendable {
    var onLine: ((String) -> Void)?
    /// When `terminatesAsSoonAsAssigned` is set, assigning `onTerminate` fires it immediately —
    /// mirroring `LiveControlModeProcess`'s synchronous replay for a process that already
    /// terminated before its caller wired a handler (the real-world shape
    /// `ControlModeActivitySourceTests.spawnClientRegistersBeforeWiringHandlers...` exercises).
    var onTerminate: (() -> Void)? {
        didSet {
            if terminatesAsSoonAsAssigned {
                onTerminate?()
            }
        }
    }
    private(set) var terminateCallCount = 0
    var terminatesAsSoonAsAssigned = false

    /// Fires `onTerminate`, mirroring `LiveControlModeProcess`: its doc comment guarantees
    /// `onTerminate` fires on *any* exit, deliberate or not, so the caller-initiated path (a
    /// session being reaped) must produce the same observable event a spontaneous crash does.
    func terminate() {
        terminateCallCount += 1
        onTerminate?()
    }

    /// Test-only: simulates one complete control-mode line arriving from the (fake) process.
    func emit(_ line: String) {
        onLine?(line)
    }

    /// Test-only: simulates the process dying on its own (session killed, tmux server exited)
    /// — distinct from `terminate()`, which is what `ControlModeActivitySource` calls when *it*
    /// decides to reap a session. Both end up firing `onTerminate`, same as the real process.
    func simulateTermination() {
        onTerminate?()
    }
}

/// Fakes `ControlModeReconnectScheduler`: records every scheduled delay (so a test can assert
/// backoff pacing/growth) and only ever runs a scheduled action when the test explicitly drains
/// it via `fireNext()` — never automatically, never on a real clock.
private final class FakeScheduler: ControlModeReconnectScheduler, @unchecked Sendable {
    private struct Scheduled {
        let delay: TimeInterval
        let action: () -> Void
    }

    private var pending: [Scheduled] = []
    private let lock = NSLock()

    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        pending.append(Scheduled(delay: delay, action: action))
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    var pendingDelays: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return pending.map(\.delay)
    }

    /// Runs the earliest-scheduled still-pending action (FIFO), the way a single-threaded event
    /// loop drains its next-due timer. Returns `false` if nothing was pending.
    @discardableResult
    func fireNext() -> Bool {
        lock.lock()
        guard !pending.isEmpty else {
            lock.unlock()
            return false
        }
        let next = pending.removeFirst()
        lock.unlock()
        next.action()
        return true
    }
}

/// Records one `FakeControlModeProcess` per launched target (session name), keyed by target so
/// a test can fetch the exact fake it needs to drive `%output` lines into. `launchCount(for:)`
/// rather than an ordered `launchedTargets` array: `ControlModeActivitySource` diffs `Set`s
/// internally, so spawn order across two sessions is not guaranteed and must never be asserted.
private final class FakeControlModeProcessLauncher: ControlModeProcessLauncher, @unchecked Sendable {
    private enum LaunchFailure: Error { case simulated }

    private var processesByTarget: [String: FakeControlModeProcess] = [:]
    private var launchCounts: [String: Int] = [:]
    private var failingTargets: Set<String> = []
    private var preTerminatingTargets: Set<String> = []
    private let lock = NSLock()

    func launch(tmuxPath: String, target: String) throws -> any ControlModeProcess {
        lock.lock()
        defer { lock.unlock() }
        launchCounts[target, default: 0] += 1
        guard !failingTargets.contains(target) else {
            throw LaunchFailure.simulated
        }
        let process = FakeControlModeProcess()
        if preTerminatingTargets.remove(target) != nil {
            process.terminatesAsSoonAsAssigned = true
        }
        processesByTarget[target] = process
        return process
    }

    /// Test-only: makes every subsequent `launch(target:)` call for `target` throw, until
    /// `setShouldFail(false, for:)` clears it — models tmux still being down (or the session
    /// still gone) across one or more reconnect attempts.
    func setShouldFail(_ shouldFail: Bool, for target: String) {
        lock.lock()
        defer { lock.unlock() }
        if shouldFail {
            failingTargets.insert(target)
        } else {
            failingTargets.remove(target)
        }
    }

    /// Test-only: makes the *next* process launched for `target` fire `onTerminate` the instant
    /// it's assigned a handler — simulating a process that already terminated before its caller
    /// wired `onTerminate`, the race `LiveControlModeProcess`'s setter-replay (ADR-0005) closes.
    func terminateNextProcessAsSoonAsHandlerAssigned(for target: String) {
        lock.lock()
        defer { lock.unlock() }
        preTerminatingTargets.insert(target)
    }

    func launchCount(for target: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return launchCounts[target] ?? 0
    }

    /// The most recently spawned fake process for `target` — the one whose `onLine` the
    /// source under test actually wired up.
    func process(for target: String) -> FakeControlModeProcess? {
        lock.lock()
        defer { lock.unlock() }
        return processesByTarget[target]
    }

    /// Test-only: drops this launcher's own strong reference to `target`'s spawned process, so
    /// a test can assert deallocation once `ControlModeActivitySource`'s `clientsBySession` (the
    /// only other intended strong referrer) has released it too.
    func forgetProcess(for target: String) {
        lock.lock()
        defer { lock.unlock() }
        processesByTarget.removeValue(forKey: target)
    }
}

/// Injectable clock so tests can assert 250ms coalescing behavior deterministically, without
/// real sleeps — advanced explicitly between `emit` calls.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 0)) {
        self.current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

/// `ControlModeActivitySource`'s steady-state happy path (SPEC §3.2, feature
/// `2026-08-15-control-mode-activity-source.md`): per-session Control Client spawn/reap driven
/// by `setWatchedPanes`, and 250ms-per-pane `onOutput` coalescing. Reconnect-on-`%exit` and
/// full-server-restart backoff are explicitly out of scope — TASK-027.
@Suite struct ControlModeActivitySourceTests {
    // MARK: - Acceptance item 1: one Control Client per session, not per pane

    @Test func setWatchedPanesSpawnsExactlyOneClientPerNewSession() {
        let launcher = FakeControlModeProcessLauncher()
        let source = ControlModeActivitySource(launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux")

        source.setWatchedPanes(["%1": "agents", "%2": "agents"])

        #expect(launcher.launchCount(for: "agents") == 1)
    }

    // MARK: - Acceptance item 2: unchanged session set does not re-spawn

    @Test func setWatchedPanesAgainWithSameSessionUnchangedDoesNotRespawn() {
        let launcher = FakeControlModeProcessLauncher()
        let source = ControlModeActivitySource(launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux")

        source.setWatchedPanes(["%1": "agents", "%2": "agents"])
        // Same session, different (still non-empty) pane composition — still just "agents".
        source.setWatchedPanes(["%1": "agents", "%3": "agents"])

        #expect(launcher.launchCount(for: "agents") == 1)
    }

    // MARK: - Acceptance item 3: reap on session disappearance

    @Test func setWatchedPanesWithSessionsPanesRemovedReapsThatSessionsClient() {
        let launcher = FakeControlModeProcessLauncher()
        let source = ControlModeActivitySource(launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux")

        source.setWatchedPanes(["%1": "agents"])
        let process = launcher.process(for: "agents")
        source.setWatchedPanes([:]) // "agents" no longer has any watched pane

        #expect(process?.terminateCallCount == 1)
    }

    /// Regression test for a retain cycle in `spawnClient`: `onLine`/`onTerminate` used to
    /// capture `process` strongly while being stored *on* `process` itself
    /// (`FakeControlModeProcess.onLine`/`onTerminate`, mirroring `LiveControlModeProcess`'s real
    /// storage), so a reaped process never deallocated — leaking its underlying `Process`/`Pipe`/
    /// `FileHandle`s indefinitely in a long-running app. `forgetProcess` drops the fake
    /// launcher's own strong reference first so `clientsBySession` (dropped by `setWatchedPanes`
    /// below) is the only referrer left standing between this and a dangling weak reference.
    @Test func reapingASessionReleasesItsProcessRatherThanLeakingItViaARetainCycle() {
        let launcher = FakeControlModeProcessLauncher()
        let source = ControlModeActivitySource(launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux")

        source.setWatchedPanes(["%1": "agents"])
        weak var weakProcess = launcher.process(for: "agents")
        launcher.forgetProcess(for: "agents")
        source.setWatchedPanes([:]) // reaps "agents"

        #expect(weakProcess == nil)
    }

    // MARK: - Acceptance item 4: 250ms per-pane coalescing

    @Test func severalOutputLinesForSamePaneWithin250msProduceExactlyOneOnOutputCall() {
        let launcher = FakeControlModeProcessLauncher()
        let clock = FakeClock()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", clock: clock.now
        )
        source.setWatchedPanes(["%1": "agents"])
        let process = launcher.process(for: "agents")!

        var firedPaneIds: [String] = []
        source.onOutput = { paneId, _ in firedPaneIds.append(paneId) }

        process.emit("%output %1 a")
        clock.advance(by: 0.1) // still inside the 250ms window
        process.emit("%output %1 b")
        clock.advance(by: 0.05) // still inside the 250ms window (0.15s since the first fire)
        process.emit("%output %1 c")

        #expect(firedPaneIds == ["%1"])
    }

    // MARK: - Acceptance item 5: independent coalescing across panes in the same session

    @Test func outputLinesForTwoDifferentPanesInSameSessionEachCoalesceIndependently() {
        let launcher = FakeControlModeProcessLauncher()
        let clock = FakeClock()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", clock: clock.now
        )
        source.setWatchedPanes(["%1": "agents", "%2": "agents"])
        let process = launcher.process(for: "agents")!

        var firedPaneIds: [String] = []
        source.onOutput = { paneId, _ in firedPaneIds.append(paneId) }

        process.emit("%output %1 a") // first for %1 — fires
        process.emit("%output %2 a") // first for %2 — fires independently
        process.emit("%output %1 b") // still inside %1's 250ms window — coalesced away
        process.emit("%output %2 b") // still inside %2's 250ms window — coalesced away

        #expect(firedPaneIds == ["%1", "%2"])
    }

    // MARK: - Post-attach settle window (tmux's terminal-mode replay must not read as real output)

    /// Bug repro: live-verified against a real tmux 3.6a server that a pane whose foreground
    /// program has an active terminal mode (Claude Code's Kitty keyboard-protocol enable
    /// sequences) gets that mode state replayed as a genuine `%output` within ~100ms of `%end` —
    /// on *every* attach this adapter makes, not only a short-lived hover-preview one. Left
    /// unhandled, this painted every untouched Claude Code Tile active the instant this app
    /// started watching its session. `%end` (`.attachConfirmed`) anchors the settle window;
    /// an `.output` line arriving inside it must be dropped.
    @Test func outputArrivingRightAfterAttachConfirmedIsSuppressed() {
        let launcher = FakeControlModeProcessLauncher()
        let clock = FakeClock()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", clock: clock.now
        )
        source.setWatchedPanes(["%1": "agents"])
        let process = launcher.process(for: "agents")!

        var firedPaneIds: [String] = []
        source.onOutput = { paneId, _ in firedPaneIds.append(paneId) }

        process.emit("%end 0 0 0")
        process.emit("%output %1 \u{1B}[>1u") // tmux's terminal-mode replay, not real typing

        #expect(firedPaneIds.isEmpty)
    }

    /// The mirror case: once the settle window has elapsed, `.output` is trusted again —
    /// otherwise a session would be permanently deaf to its own panes after every attach.
    @Test func outputArrivingAfterSettleWindowElapsesFiresNormally() {
        let launcher = FakeControlModeProcessLauncher()
        let clock = FakeClock()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", clock: clock.now
        )
        source.setWatchedPanes(["%1": "agents"])
        let process = launcher.process(for: "agents")!

        var firedPaneIds: [String] = []
        source.onOutput = { paneId, _ in firedPaneIds.append(paneId) }

        process.emit("%end 0 0 0")
        clock.advance(by: 1.5) // past the 1.0s settle window
        process.emit("%output %1 real typing")

        #expect(firedPaneIds == ["%1"])
    }

    /// The specific regression a naive "mute every pane for a while after any confirmation"
    /// implementation would reintroduce: `%1`'s own first `.output` (with no `%end` ever having
    /// arrived for this process) is the sole confirmation event `%2` has to go on. `%2`'s
    /// unrelated first `.output`, arriving right after, must still fire — it is not settle-window
    /// noise from `%1`'s attach, since `%2` never had its own `%end` suppressed.
    @Test func anotherPanesFirstOutputIsNotSuppressedByAConfirmationCreditedToADifferentPane() {
        let launcher = FakeControlModeProcessLauncher()
        let clock = FakeClock()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", clock: clock.now
        )
        source.setWatchedPanes(["%1": "agents", "%2": "agents"])
        let process = launcher.process(for: "agents")!

        var firedPaneIds: [String] = []
        source.onOutput = { paneId, _ in firedPaneIds.append(paneId) }

        process.emit("%output %1 a") // no %end ever arrived — this is %1's own confirmation
        process.emit("%output %2 a") // must not be read as settle-window noise from %1's confirm

        #expect(firedPaneIds == ["%1", "%2"])
    }

    /// Bug repro: live-verified against a real tmux 3.6a server that anchoring the settle window
    /// solely to this process's own `%end` misses the far more common trigger — an *unrelated*
    /// client attaching to the same session (another `PaneWatch` cold start, a hover-preview
    /// grouped-session create or teardown, a manual `tmux attach`) rebroadcasts the same
    /// terminal-mode replay to every client already watching that session, including one settled
    /// minutes earlier. `%client-session-changed` (classified `.other`) is exactly the
    /// notification live captures show landing right before that replay; an `.output` line
    /// arriving inside the window it arms must be dropped the same way `%end`'s window is.
    @Test func outputArrivingRightAfterAnotherClientsSessionChangeIsSuppressed() {
        let launcher = FakeControlModeProcessLauncher()
        let clock = FakeClock()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", clock: clock.now
        )
        source.setWatchedPanes(["%1": "agents"])
        let process = launcher.process(for: "agents")!

        var firedPaneIds: [String] = []
        source.onOutput = { paneId, _ in firedPaneIds.append(paneId) }

        process.emit("%end 0 0 0")
        clock.advance(by: 5.0) // long settled — the original %end-anchored window is well past
        process.emit("%client-session-changed client-99 $3 agents") // an unrelated client attached
        process.emit("%output %1 \u{1B}[>1u") // the replay that broadcast triggers, not real typing

        #expect(firedPaneIds.isEmpty)
    }

    // MARK: - Acceptance item 6: `.exit`/`.other` never directly trigger `onOutput`

    /// Falsifiable against "onLine was never wired at all" (which would trivially pass a test
    /// that only emits `.exit`/`.other` and checks for zero fires): mixes `%exit` and an
    /// unrecognized `%`-prefixed line in with one real `%output` for a watched pane, past the
    /// settle window `.other` now arms (see the `MARK` below), and asserts that exactly the
    /// `%output` line produced a fire — proving `.exit`/`.other` were parsed and deliberately
    /// dropped, not just never reaching the parser.
    @Test func exitAndOtherEventsNeverDirectlyTriggerOnOutput() {
        let launcher = FakeControlModeProcessLauncher()
        let clock = FakeClock()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", clock: clock.now
        )
        source.setWatchedPanes(["%1": "agents"])
        let process = launcher.process(for: "agents")!

        var firedPaneIds: [String] = []
        source.onOutput = { paneId, _ in firedPaneIds.append(paneId) }

        process.emit("%exit")
        process.emit("%session-changed $0 agents") // unrecognized-as-output — classifies .other
        clock.advance(by: 1.5) // past the 1.0s settle window .other just armed
        process.emit("%output %1 real output")

        #expect(firedPaneIds == ["%1"])
    }

    // MARK: - TASK-027 acceptance item 1: single-session reconnect, others unaffected

    @Test func singleSessionClientTerminatingWithOthersAliveReconnectsOnlyThatSession() {
        let launcher = FakeControlModeProcessLauncher()
        let scheduler = FakeScheduler()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", scheduler: scheduler
        )
        source.setWatchedPanes(["%1": "agents", "%2": "other"])
        let agentsProcess = launcher.process(for: "agents")!

        agentsProcess.simulateTermination()
        scheduler.fireNext() // drains the batch-settle tick

        #expect(launcher.launchCount(for: "agents") == 2)
        #expect(launcher.launchCount(for: "other") == 1)
    }

    // MARK: - TASK-027 acceptance item 2: simultaneous pool-wide termination is one backoff sequence

    /// Falsifiable against "each termination just reconnects independently" (which would also
    /// leave every session reconnected, so counting relaunches can't tell the two designs
    /// apart): makes both sessions' relaunch attempts fail, fires both terminations before the
    /// batch-settle tick runs, and asserts exactly one retry gets scheduled — one shared backoff
    /// sequence covering the whole pool, not two independent per-session ones (which would show
    /// up as two scheduled retries here).
    @Test func allLiveClientsTerminatingWithinSameTickScheduleExactlyOneRetry() {
        let launcher = FakeControlModeProcessLauncher()
        let scheduler = FakeScheduler()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", scheduler: scheduler
        )
        source.setWatchedPanes(["%1": "agents", "%2": "other"])
        let agentsProcess = launcher.process(for: "agents")!
        let otherProcess = launcher.process(for: "other")!
        launcher.setShouldFail(true, for: "agents")
        launcher.setShouldFail(true, for: "other")

        // Both fire before anything drains the scheduler — "within the same tick."
        agentsProcess.simulateTermination()
        otherProcess.simulateTermination()
        #expect(scheduler.pendingCount == 1) // the single batch-settle tick, not one per session

        scheduler.fireNext() // batch-settle tick runs attemptReconnect once for both sessions

        #expect(scheduler.pendingCount == 1) // exactly one retry scheduled, covering the pool
    }

    // MARK: - TASK-027 acceptance item 3: failed reconnect retries are paced on backoff, not spun

    @Test func failedPoolReconnectRetriesAreDelayedAndGrowRatherThanSpinning() {
        let launcher = FakeControlModeProcessLauncher()
        let scheduler = FakeScheduler()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", scheduler: scheduler
        )
        source.setWatchedPanes(["%1": "agents", "%2": "other"])
        let agentsProcess = launcher.process(for: "agents")!
        let otherProcess = launcher.process(for: "other")!
        launcher.setShouldFail(true, for: "agents")
        launcher.setShouldFail(true, for: "other")

        agentsProcess.simulateTermination()
        otherProcess.simulateTermination()
        scheduler.fireNext() // batch-settle tick: first reconnect attempt, still failing

        // Still failing: retry #1 must be paced (non-zero delay), never immediate.
        let firstRetryDelay = scheduler.pendingDelays.last
        #expect(firstRetryDelay != nil && firstRetryDelay! > 0)
        #expect(launcher.launchCount(for: "agents") == 2) // one retry attempt so far, no spin

        scheduler.fireNext() // retry #1 fires: attempt again, still failing
        let secondRetryDelay = scheduler.pendingDelays.last
        #expect(secondRetryDelay != nil && secondRetryDelay! > firstRetryDelay!) // grows
        #expect(launcher.launchCount(for: "agents") == 3)
    }

    // MARK: - TASK-027 acceptance item 4: a successful reconnect resumes onOutput unprompted

    @Test func successfulReconnectAfterFailuresResumesOnOutputWithoutReSettingWatchedPanes() {
        let launcher = FakeControlModeProcessLauncher()
        let scheduler = FakeScheduler()
        let clock = FakeClock()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", clock: clock.now, scheduler: scheduler
        )
        source.setWatchedPanes(["%1": "agents"])
        let firstProcess = launcher.process(for: "agents")!
        launcher.setShouldFail(true, for: "agents")

        var firedPaneIds: [String] = []
        source.onOutput = { paneId, _ in firedPaneIds.append(paneId) }

        firstProcess.simulateTermination()
        scheduler.fireNext() // batch-settle tick: reconnect attempt fails (launcher still failing)
        #expect(launcher.launchCount(for: "agents") == 2)

        launcher.setShouldFail(false, for: "agents") // tmux is back
        scheduler.fireNext() // the paced retry: this attempt succeeds
        #expect(launcher.launchCount(for: "agents") == 3)

        let reconnectedProcess = launcher.process(for: "agents")!
        reconnectedProcess.emit("%output %1 resumed")

        #expect(firedPaneIds == ["%1"]) // fired without any further setWatchedPanes call
    }

    // MARK: - TASK-027 acceptance item 5: a reaped session's later termination is not reconnected

    @Test func reapedSessionTerminatingLaterDoesNotTriggerReconnect() {
        let launcher = FakeControlModeProcessLauncher()
        let scheduler = FakeScheduler()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", scheduler: scheduler
        )
        source.setWatchedPanes(["%1": "agents"])
        let process = launcher.process(for: "agents")!

        source.setWatchedPanes([:]) // reaps "agents" — calls process.terminate()
        #expect(process.terminateCallCount == 1)

        // The now-detached process dying for real (e.g. the underlying tmux client's exit
        // finally lands) must not be mistaken for an unexpected termination.
        process.simulateTermination()

        #expect(scheduler.pendingCount == 0) // nothing scheduled — no reconnect attempt at all
        #expect(launcher.launchCount(for: "agents") == 1)
    }

    // MARK: - Branch-fix regression: spawnClient registers before wiring handlers

    /// A process that terminates the instant its `onTerminate` handler is assigned (the shape a
    /// real `LiveControlModeProcess` produces when the underlying process already exited before
    /// `spawnClient` got around to wiring handlers, ADR-0005) must still be recognized by
    /// `handleTerminate` as *this session's* live client — not silently dropped because
    /// `clientsBySession` hadn't been updated yet at the moment the replay fired. Falsifiable
    /// against "wire handlers, then register in the pool" (the old ordering): under that
    /// ordering, `handleTerminate`'s identity guard (`clientsBySession[session] === process`)
    /// finds no entry at all when the replay fires mid-assignment, treats it as an already-reaped
    /// session, and schedules nothing — this session goes dark with no reconnect attempt ever
    /// made.
    @Test func spawnClientRegistersInPoolBeforeWiringHandlersSoAnImmediateReplayIsStillReconnected() {
        let launcher = FakeControlModeProcessLauncher()
        let scheduler = FakeScheduler()
        launcher.terminateNextProcessAsSoonAsHandlerAssigned(for: "agents")
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", scheduler: scheduler
        )
        var failureFired = false
        source.onFailure = { failureFired = true }

        source.setWatchedPanes(["%1": "agents"])

        #expect(failureFired) // unconfirmed termination, never-confirmed adapter
        #expect(scheduler.pendingCount == 1) // a reconnect was actually scheduled, not dropped
    }

    // MARK: - TASK-029: the concrete FailableActivitySource signal

    /// The literal example the Slice names: `ControlModeProcessLauncher.launch` throwing at
    /// attach time (e.g. an invalid `tmuxPath`) before this adapter has ever proven control
    /// mode works at all.
    @Test func launchFailureBeforeAnyConfirmationFiresOnFailure() {
        let launcher = FakeControlModeProcessLauncher()
        launcher.setShouldFail(true, for: "agents")
        let source = ControlModeActivitySource(launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux")
        var failureFired = false
        source.onFailure = { failureFired = true }

        source.setWatchedPanes(["%1": "agents"])

        #expect(failureFired)
    }

    /// Live-verified (real `tmux -C attach` against a nonexistent session): `launcher.launch`
    /// does *not* throw — the process spawns fine and tmux replies
    /// `%begin`/`<error text>`/`%error`/`%exit` before ever reaching `%end`. Without a signal
    /// for this shape, `spawnClient` reports success, `attemptReconnect` resets backoff to 0,
    /// and the resulting immediate-`%exit` retriggers the delay:0 settle tick — a real,
    /// unbounded respawn storm this test guards against by requiring both the failure signal
    /// and a paced (non-zero) retry delay.
    @Test func unconfirmedTerminationBeforeAnyConfirmationFiresOnFailureAndPacesRetry() {
        let launcher = FakeControlModeProcessLauncher()
        let scheduler = FakeScheduler()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", scheduler: scheduler
        )
        var failureFired = false
        source.onFailure = { failureFired = true }

        source.setWatchedPanes(["%1": "agents"])
        let process = launcher.process(for: "agents")!
        // Never emits %end or %output — the attach itself never confirmed before dying.
        process.simulateTermination()

        #expect(failureFired)
        let delay = scheduler.pendingDelays.last
        #expect(delay != nil && delay! > 0)
    }

    /// Falsifiable against "fires on any failure, ever" (the design the second unit test in
    /// `FallbackActivitySourceTests` exists to distinguish at the `FallbackActivitySource`
    /// layer): once *any* session has proven control mode works, a later, unrelated session's
    /// unconfirmed death must not report failure again — that ongoing case is TASK-027's
    /// retry-forever contract, not a fallback-worthy signal.
    @Test func unconfirmedFailureAfterAnyPriorConfirmationDoesNotFireOnFailure() {
        let launcher = FakeControlModeProcessLauncher()
        let scheduler = FakeScheduler()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", scheduler: scheduler
        )
        source.setWatchedPanes(["%1": "agents", "%2": "other"])
        let agentsProcess = launcher.process(for: "agents")!
        agentsProcess.emit("%end 1 1 0") // confirms the pool at least once
        let otherProcess = launcher.process(for: "other")!

        var failureFired = false
        source.onFailure = { failureFired = true }

        otherProcess.simulateTermination() // "other" itself never confirmed

        #expect(!failureFired)
    }

    /// Regression guard for TASK-027 acceptance item 1 (quick single-session reconnect):
    /// confirming a session's attach must keep its later, ordinary termination on the existing
    /// immediate (delay: 0) settle-tick path — proving the new backoff pacing above is scoped
    /// to *unconfirmed* terminations only, not applied indiscriminately to every termination.
    @Test func confirmedSessionTerminatingReconnectsImmediatelyNotOnBackoff() {
        let launcher = FakeControlModeProcessLauncher()
        let scheduler = FakeScheduler()
        let source = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", scheduler: scheduler
        )
        source.setWatchedPanes(["%1": "agents"])
        let process = launcher.process(for: "agents")!
        process.emit("%end 1 1 0") // confirms

        process.simulateTermination()

        #expect(scheduler.pendingDelays == [0])
    }

    // MARK: - Branch-fix regression: an abandoned primary stops respawning after FallbackActivitySource switches

    /// End-to-end through the real `FallbackActivitySource` composition (not a fake standing in
    /// for `ControlModeActivitySource`): the unconfirmed-termination shape is this feature's
    /// primary motivating case (old tmux where control mode misbehaves), and it's the shape that
    /// loops — `spawnClient` succeeds, the process dies unconfirmed, `onFailure` fires and
    /// switches to `secondary`, but without `FallbackActivitySource` telling `primary` to stop,
    /// `primary`'s own TASK-027 supervision keeps rescheduling a reconnect against a session
    /// `secondary` is now the only one reporting on. Falsifiable against the pre-fix
    /// `switchToSecondary` (no `primary.setWatchedPanes([:])` call): draining the scheduler there
    /// respawns "agents" once per drain forever — `launchCount` climbs and a new retry is always
    /// pending. Bounded to 5 drains rather than looped to exhaustion, per CLAUDE.md's ban on
    /// tests that can hang under the very bug they're checking for.
    @Test func fallbackSwitchStopsPrimaryFromRespawningOnUnconfirmedTermination() {
        let launcher = FakeControlModeProcessLauncher()
        let scheduler = FakeScheduler()
        let primary = ControlModeActivitySource(
            launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux", scheduler: scheduler
        )
        let secondary = RecordingActivitySource()
        let fallback = FallbackActivitySource(primary: primary, secondary: secondary)

        fallback.setWatchedPanes(["%1": "agents"])
        // Never emits %end or %output — the attach itself never confirmed before dying. This is
        // what fires `onFailure` and trips the switch.
        launcher.process(for: "agents")!.simulateTermination()

        for _ in 0..<5 { scheduler.fireNext() }

        #expect(launcher.launchCount(for: "agents") == 1) // no reconnect ever attempted post-switch
        #expect(scheduler.pendingCount == 0) // nothing left pacing a future respawn either
    }
}

/// Minimal `ActivitySource` fake for the `FallbackActivitySource` integration test above — this
/// file already has `FakeControlModeProcess`/`FakeControlModeProcessLauncher`/`FakeScheduler` for
/// standing in as the real `ControlModeActivitySource`'s dependencies, so `secondary` only needs
/// to exist, not do anything observable.
private final class RecordingActivitySource: ActivitySource, @unchecked Sendable {
    var onOutput: ((String, Date) -> Void)?
    func setWatchedPanes(_ panes: [String: String]) {}
}
