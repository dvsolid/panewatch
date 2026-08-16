import Foundation
import Testing
@testable import TmuxCore

/// Fakes `ControlModeProcessLauncher`/`ControlModeProcess` (no real `tmux -C attach`
/// subprocess) so `ControlModeActivitySource`'s pool/coalescing logic is exercised at the
/// `ActivitySource` seam without depending on a live tmux server — mirrors
/// `PollingActivitySourceTests.FakeTmuxGateway`'s role for `PollingActivitySource`.
private final class FakeControlModeProcess: ControlModeProcess, @unchecked Sendable {
    var onLine: ((String) -> Void)?
    var onTerminate: (() -> Void)?
    private(set) var terminateCallCount = 0

    func terminate() {
        terminateCallCount += 1
    }

    /// Test-only: simulates one complete control-mode line arriving from the (fake) process.
    func emit(_ line: String) {
        onLine?(line)
    }
}

/// Records one `FakeControlModeProcess` per launched target (session name), keyed by target so
/// a test can fetch the exact fake it needs to drive `%output` lines into. `launchCount(for:)`
/// rather than an ordered `launchedTargets` array: `ControlModeActivitySource` diffs `Set`s
/// internally, so spawn order across two sessions is not guaranteed and must never be asserted.
private final class FakeControlModeProcessLauncher: ControlModeProcessLauncher, @unchecked Sendable {
    private var processesByTarget: [String: FakeControlModeProcess] = [:]
    private var launchCounts: [String: Int] = [:]
    private let lock = NSLock()

    func launch(tmuxPath: String, target: String) throws -> any ControlModeProcess {
        lock.lock()
        defer { lock.unlock() }
        launchCounts[target, default: 0] += 1
        let process = FakeControlModeProcess()
        processesByTarget[target] = process
        return process
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

    // MARK: - Acceptance item 6: `.exit`/`.other` never directly trigger `onOutput`

    /// Falsifiable against "onLine was never wired at all" (which would trivially pass a test
    /// that only emits `.exit`/`.other` and checks for zero fires): mixes `%exit` and an
    /// unrecognized `%`-prefixed line in with one real `%output` for a watched pane, and asserts
    /// that exactly the `%output` line produced a fire — proving `.exit`/`.other` were parsed and
    /// deliberately dropped, not just never reaching the parser.
    @Test func exitAndOtherEventsNeverDirectlyTriggerOnOutput() {
        let launcher = FakeControlModeProcessLauncher()
        let source = ControlModeActivitySource(launcher: launcher, tmuxPath: "/opt/homebrew/bin/tmux")
        source.setWatchedPanes(["%1": "agents"])
        let process = launcher.process(for: "agents")!

        var firedPaneIds: [String] = []
        source.onOutput = { paneId, _ in firedPaneIds.append(paneId) }

        process.emit("%exit")
        process.emit("%session-changed $0 agents") // unrecognized-as-output — classifies .other
        process.emit("%output %1 real output")

        #expect(firedPaneIds == ["%1"])
    }
}
