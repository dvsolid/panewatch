import Foundation
import Testing
@testable import TmuxCore

/// Records every `setWatchedPanes`/`onOutput` interaction so a test can assert traffic shape
/// (call counts, last payload) rather than just final state — the plain half of the two-fake
/// pair `FallbackActivitySourceTests`' Test seam calls for. Used as `secondary` in every test
/// (never fails, never needs to be the one failing).
private final class FakeActivitySource: ActivitySource, @unchecked Sendable {
    var onOutput: ((String, Date) -> Void)?
    private(set) var setWatchedPanesCallCount = 0
    private(set) var lastWatchedPanes: [String: String] = [:]

    func setWatchedPanes(_ panes: [String: String]) {
        setWatchedPanesCallCount += 1
        lastWatchedPanes = panes
    }

    /// Test-only: simulates output arriving from this source's watched pane.
    func fireOutput(paneId: String, at date: Date = Date()) {
        onOutput?(paneId, date)
    }
}

/// The failure-injectable half of the pair: conforms to `FailableActivitySource` so it can stand
/// in as `FallbackActivitySource`'s `primary`. `simulateFailure()` is the test's hand on the
/// "defined failure signal" the Slice refers to — this task defines that signal generically
/// (`onFailure`), independent of what `ControlModeActivitySource` will eventually call it for
/// (TASK-029).
private final class FakeFailableActivitySource: FailableActivitySource, @unchecked Sendable {
    var onOutput: ((String, Date) -> Void)?
    var onFailure: (() -> Void)?
    private(set) var setWatchedPanesCallCount = 0
    private(set) var lastWatchedPanes: [String: String] = [:]

    func setWatchedPanes(_ panes: [String: String]) {
        setWatchedPanesCallCount += 1
        lastWatchedPanes = panes
    }

    /// Test-only: simulates output arriving from this source's watched pane.
    func fireOutput(paneId: String, at date: Date = Date()) {
        onOutput?(paneId, date)
    }

    /// Test-only: trips `onFailure`, the generic signal `FallbackActivitySource` listens for.
    func simulateFailure() {
        onFailure?()
    }
}

@Suite struct FallbackActivitySourceTests {
    @Test func withHealthyPrimaryAllTrafficPassesThroughAndSecondaryUntouched() {
        let primary = FakeFailableActivitySource()
        let secondary = FakeActivitySource()
        let fallback = FallbackActivitySource(primary: primary, secondary: secondary)
        var firedPaneIds: [String] = []
        fallback.onOutput = { paneId, _ in firedPaneIds.append(paneId) }

        fallback.setWatchedPanes(["%1": "sess"])
        primary.fireOutput(paneId: "%1")
        // Secondary firing while primary is healthy must never surface — it isn't the active
        // route yet, even though `FallbackActivitySource` wires its `onOutput` up front.
        secondary.fireOutput(paneId: "%2")

        #expect(primary.setWatchedPanesCallCount == 1)
        #expect(primary.lastWatchedPanes == ["%1": "sess"])
        #expect(secondary.setWatchedPanesCallCount == 0)
        #expect(firedPaneIds == ["%1"])
    }

    @Test func onPrimaryFailureSubsequentTrafficRoutesToSecondary() {
        let primary = FakeFailableActivitySource()
        let secondary = FakeActivitySource()
        let fallback = FallbackActivitySource(primary: primary, secondary: secondary)
        var firedPaneIds: [String] = []
        fallback.onOutput = { paneId, _ in firedPaneIds.append(paneId) }

        fallback.setWatchedPanes(["%1": "sess"])
        primary.simulateFailure()

        // The switch itself replays the most recently requested pane map to `secondary` — without
        // this, a real `PollingActivitySource` secondary would have never been told what to watch
        // and could never surface any `onOutput` at all, which the second half of this acceptance
        // item (surfacing secondary's onOutput events) requires in production, not just in a test
        // that can fire a fake's `onOutput` directly.
        #expect(secondary.lastWatchedPanes == ["%1": "sess"])

        fallback.setWatchedPanes(["%2": "sess"])
        secondary.fireOutput(paneId: "%2")

        #expect(secondary.lastWatchedPanes == ["%2": "sess"])
        #expect(secondary.setWatchedPanesCallCount == 2) // replay + the one subsequent call
        // Post-switch, `primary` gets exactly one more call: the teardown to an empty pane map
        // (never real traffic again) — proving the abandoned primary is told to stop watching,
        // not just that it stops receiving new watch requests.
        #expect(primary.setWatchedPanesCallCount == 2)
        #expect(primary.lastWatchedPanes == [:])
        #expect(firedPaneIds == ["%2"])
    }

    @Test func onceSwitchedNeverFlapsBackToPrimary() {
        let primary = FakeFailableActivitySource()
        let secondary = FakeActivitySource()
        let fallback = FallbackActivitySource(primary: primary, secondary: secondary)
        var firedPaneIds: [String] = []
        fallback.onOutput = { paneId, _ in firedPaneIds.append(paneId) }

        fallback.setWatchedPanes(["%1": "sess"])
        primary.simulateFailure()
        let primaryCallCountAtSwitch = primary.setWatchedPanesCallCount

        // A second failure signal (e.g. the primary's own supervision logic keeps trying and
        // fails again) must not re-trigger anything — the switch already happened.
        primary.simulateFailure()
        fallback.setWatchedPanes(["%2": "sess"])
        fallback.setWatchedPanes(["%3": "sess"])

        // A stale primary that somehow still emits output after being abandoned must never
        // surface — this is the real "stays on secondary" latch, not just a call-count check.
        primary.fireOutput(paneId: "%1")

        #expect(primary.setWatchedPanesCallCount == primaryCallCountAtSwitch)
        #expect(secondary.setWatchedPanesCallCount == 3) // replay-at-switch + the two subsequent calls
        #expect(secondary.lastWatchedPanes == ["%3": "sess"])
        #expect(firedPaneIds.isEmpty)
    }
}
