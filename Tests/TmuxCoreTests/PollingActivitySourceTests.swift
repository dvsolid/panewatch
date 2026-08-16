import Foundation
import Testing
@testable import TmuxCore

/// Fakes `TmuxGateway` so `PollingActivitySource` tests never spawn real tmux. Counts
/// `capturePane` invocations per pane so tests can assert the single-spawn-per-tick discipline
/// (this task's acceptance item 6), and returns scripted output per pane so tests control
/// exactly when the hash changes.
private final class FakeTmuxGateway: TmuxGateway, @unchecked Sendable {
    private(set) var captureCallCount: [String: Int] = [:]
    var output: [String: String]
    private let lock = NSLock()

    init(output: [String: String]) {
        self.output = output
    }

    func listPanes() throws -> String { "" }

    /// Unused by any test in this file — required to conform to `TmuxGateway`.
    func listClients() throws -> String { "" }

    func capturePane(_ paneId: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        captureCallCount[paneId, default: 0] += 1
        return output[paneId] ?? ""
    }

    func callCount(for paneId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return captureCallCount[paneId] ?? 0
    }

    /// Unused by any test in this file — required to conform to `TmuxGateway`.
    func run(_ arguments: [String]) throws -> String { "" }
}

/// Deliberately far outside any plausible test runtime: `PollingActivitySource` starts its
/// internal probe timer in `init` (production behavior — see the type's doc comment), and
/// `swift test` runs the whole suite in one process. A short `probeInterval` here could let an
/// instance's own background timer fire mid-suite and corrupt call counts nondeterministically;
/// this value structurally rules that out rather than relying on the suite happening to run fast.
private let farProbeInterval: TimeInterval = 3600

/// Acceptance item 6: `PollingActivitySource` spawns exactly one `capture-pane` per watched
/// pane per `probeInterval` tick — no more. Exercised at the declared seam: a faked
/// `TmuxGateway`, ticked once via the internal probe pass (no real timer under test — this
/// task's Test seam scopes timer/subprocess machinery out of these tests).
@Test func probeOnceCapturesEachWatchedPaneExactlyOnce() {
    let gateway = FakeTmuxGateway(output: ["%1": "hello", "%2": "world"])
    let source = PollingActivitySource(gateway: gateway, probeInterval: farProbeInterval)
    source.setWatchedPanes(["%1": "sess", "%2": "sess"])

    source.probeOnce()

    #expect(gateway.callCount(for: "%1") == 1)
    #expect(gateway.callCount(for: "%2") == 1)
}

/// Consecutive-hash-diff behavior: `onOutput` fires only when a pane's captured screen changes
/// between ticks, not on every tick and not on the first-ever sample (nothing to diff against
/// yet).
@Test func firesOnOutputWhenConsecutiveHashesDiffer() {
    let gateway = FakeTmuxGateway(output: ["%1": "frame-1"])
    let source = PollingActivitySource(gateway: gateway, probeInterval: farProbeInterval)
    source.setWatchedPanes(["%1": "sess"])

    var firedPaneIds: [String] = []
    source.onOutput = { paneId, _ in firedPaneIds.append(paneId) }

    source.probeOnce() // first sample — nothing to diff against yet
    #expect(firedPaneIds.isEmpty)

    source.probeOnce() // unchanged output — no fire
    #expect(firedPaneIds.isEmpty)

    gateway.output["%1"] = "frame-2"
    source.probeOnce() // changed output — fires
    #expect(firedPaneIds == ["%1"])
}

/// Item 2's behavior regression guard: `setWatchedPanes` still evicts a dropped pane's cached
/// hash when fed the new `[String: String]` shape (derived from `Set(panes.keys)`), exactly as
/// it did against the old `Set<String>` input. A pane that leaves the watched set and later
/// rejoins must be treated as a fresh, un-diffed sample — never compared against content
/// captured before it was dropped, even if that content changed while unwatched.
@Test func rewatchingAPaneAfterDroppingItTreatsItAsAFreshSample() {
    let gateway = FakeTmuxGateway(output: ["%1": "frame-1"])
    let source = PollingActivitySource(gateway: gateway, probeInterval: farProbeInterval)
    source.setWatchedPanes(["%1": "sess"])

    var firedPaneIds: [String] = []
    source.onOutput = { paneId, _ in firedPaneIds.append(paneId) }

    source.probeOnce() // establishes a hash for "frame-1" — first sample, no fire
    #expect(firedPaneIds.isEmpty)

    source.setWatchedPanes([:]) // %1 drops out — its cached hash must be evicted
    gateway.output["%1"] = "frame-2" // content changes while unwatched
    source.setWatchedPanes(["%1": "sess"]) // %1 rejoins

    source.probeOnce() // no prior hash survived the drop, so this is a fresh sample — no fire,
    // even though "frame-2" differs from the last content seen before %1 was dropped
    #expect(firedPaneIds.isEmpty)
}
