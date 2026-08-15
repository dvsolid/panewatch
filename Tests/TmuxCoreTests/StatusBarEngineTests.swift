import Foundation
import Testing
@testable import TmuxCore

/// Fakes `TmuxGateway` with a *mutable* `listPanes` output, so a test can simulate successive
/// discovery passes (this task's Test seam: "ticks driven directly in the test, not by
/// wall-clock time") by reassigning `output` between `StatusBarEngine.reconcile()` calls.
/// Counts `listPanes()` invocations so acceptance item 4 (one spawn per `reconcile`, none from
/// `tiles`) is directly assertable.
private final class FakeTmuxGateway: TmuxGateway, @unchecked Sendable {
    var output: String
    private(set) var listPanesCallCount = 0

    init(output: String) {
        self.output = output
    }

    func listPanes() throws -> String {
        listPanesCallCount += 1
        return output
    }

    func capturePane(_ paneId: String) throws -> String { "" }
}

/// A stand-in `ActivitySource` that records whatever `onOutput` handler `StatusBarEngine.init`
/// wires up and lets a test fire it directly — this is the actual production path an agent's
/// output reaches `ActivityStateStore` through, so `phaseIsPreservedAcrossReconciliation` drives
/// it here rather than poking `ActivityStateStore` directly.
private final class FakeActivitySource: ActivitySource, @unchecked Sendable {
    var onOutput: ((String, Date) -> Void)?
    func setWatchedPanes(_ paneIds: Set<String>) {}
    func fireOutput(paneId: String, at date: Date) { onOutput?(paneId, date) }
}

/// One `list-panes -a` raw-pane-line, `ProcessTmuxGateway.paneFormat`-shaped. Builds a minimal
/// controlled fixture line per pane rather than reusing `capturedPaneListFixture` — these tests
/// need to construct specific successive-pass scenarios (a pane present in one pass and absent
/// in the next), which a single frozen fixture can't express.
private func paneLine(
    id: String,
    session: String = "sess",
    windowIndex: Int = 1,
    paneIndex: Int,
    command: String = "node",
    title: String,
    pid: Int32
) -> String {
    "\(id)|\(session)|\(windowIndex)|main|\(paneIndex)|\(command)|\(title)|\(pid)|/dev/ttys00\(paneIndex)|/path|0||0"
}

private let claudeTaskOne = paneLine(id: "%1", paneIndex: 1, title: "✳ task-one", pid: 100)
private let claudeTaskThree = paneLine(id: "%3", paneIndex: 3, title: "✳ task-three", pid: 300)
private let piTaskTwo = paneLine(id: "%2", paneIndex: 2, command: "zsh", title: "π - proj", pid: 200)

/// TASK-013: title matches are now corroborated against a live agent descendant every
/// `classify()` pass, so `AgentDetector`'s default `ProcessTableDescendantInspector` (a real
/// `ps` walk) would find none of these synthetic pids and silently exclude every Tile these
/// tests expect. Stands in a live descendant of the matching type for each fixture pane, same
/// as `AgentDetectorTests`' shared default fake.
private let fakeDescendantInspector = FakeDescendantProcessInspector(argvByPID: [
    100: ["/usr/local/bin/claude"], // %1
    200: ["/usr/local/bin/pi"], // %2
    300: ["/usr/local/bin/claude"], // %3
])

private final class FakeDescendantProcessInspector: DescendantProcessInspector, @unchecked Sendable {
    private let argvByPID: [Int32: [String]]

    init(argvByPID: [Int32: [String]]) {
        self.argvByPID = argvByPID
    }

    func descendantArgv(of pids: Set<Int32>) -> [Int32: [String]] {
        var result: [Int32: [String]] = [:]
        for pid in pids { result[pid] = argvByPID[pid] ?? [] }
        return result
    }
}

private func makeEngine(
    gateway: FakeTmuxGateway,
    activitySource: FakeActivitySource = FakeActivitySource()
) -> StatusBarEngine {
    StatusBarEngine(
        discovery: PaneDiscovery(gateway: gateway),
        detector: AgentDetector(descendantInspector: fakeDescendantInspector),
        activitySource: activitySource
    )
}

/// Acceptance item 1: a pane that appears in a later discovery pass (simulating a newly
/// started agent session) becomes a new Tile on the next reconciliation, with no restart —
/// exercised as two direct `reconcile()` calls against a gateway whose output changes between
/// them, per this task's Test seam.
@Test func newlyAppearedPaneBecomesATileOnNextReconciliation() throws {
    let gateway = FakeTmuxGateway(output: claudeTaskOne)
    let engine = makeEngine(gateway: gateway)

    let firstPass = try engine.reconcile()
    #expect(Set(firstPass.map(\.id)) == ["%1"])

    gateway.output = [claudeTaskOne, piTaskTwo].joined(separator: "\n")
    let secondPass = try engine.reconcile()

    #expect(Set(secondPass.map(\.id)) == ["%1", "%2"])
}

/// Acceptance item 2: a pane that disappears from a later discovery pass (simulating a closed
/// agent pane) has its Tile removed on the next reconciliation.
@Test func closedPaneTileIsRemovedOnNextReconciliation() throws {
    let gateway = FakeTmuxGateway(output: [claudeTaskOne, claudeTaskThree].joined(separator: "\n"))
    let engine = makeEngine(gateway: gateway)

    let firstPass = try engine.reconcile()
    #expect(Set(firstPass.map(\.id)) == ["%1", "%3"])

    gateway.output = claudeTaskOne
    let secondPass = try engine.reconcile()

    #expect(Set(secondPass.map(\.id)) == ["%1"])
}

/// Acceptance item 3: a pane still present and still classifying the same way across
/// reconciliation passes keeps its Activity Phase — a `reconcile` pass that adds and removes
/// *other* panes must not reset or replace the phase state a still-open pane already has.
/// Drives output through the real `ActivitySource.onOutput` wiring (not a test-injected
/// `ActivityStateStore`), so this exercises the engine's own retained store, not a stand-in.
@Test func phaseIsPreservedAcrossReconciliation() throws {
    let gateway = FakeTmuxGateway(output: [claudeTaskOne, claudeTaskThree].joined(separator: "\n"))
    let activitySource = FakeActivitySource()
    let engine = makeEngine(gateway: gateway, activitySource: activitySource)
    let now = Date()

    _ = try engine.reconcile(now: now)
    activitySource.fireOutput(paneId: "%1", at: now)
    let firstPhase = try #require(engine.tiles(now: now).first { $0.id == "%1" }).phase
    #expect(firstPhase == .blinking)

    // Next discovery pass: %3 closes, %2 appears — %1 is untouched.
    gateway.output = [claudeTaskOne, piTaskTwo].joined(separator: "\n")
    let secondPass = try engine.reconcile(now: now)
    let secondPhase = try #require(secondPass.first { $0.id == "%1" }).phase

    #expect(secondPhase == firstPhase)
}

/// Acceptance item 4: reconciliation spawns `list-panes` exactly once per `discoveryInterval`
/// tick — never once per Tile. `reconcile()` is the only call that spawns discovery; three
/// `tiles()` calls (the `probeInterval`-cadence phase refresh, against a topology that already
/// holds 3 Tiles) must not spawn it again, regardless of how many Tiles are currently known.
@Test func reconciliationSpawnsListPanesOnceNotOncePerTile() throws {
    let gateway = FakeTmuxGateway(
        output: [claudeTaskOne, piTaskTwo, claudeTaskThree].joined(separator: "\n")
    )
    let engine = makeEngine(gateway: gateway)

    let reconciled = try engine.reconcile()
    #expect(reconciled.count == 3)
    #expect(gateway.listPanesCallCount == 1)

    _ = engine.tiles()
    _ = engine.tiles()
    _ = engine.tiles()
    #expect(gateway.listPanesCallCount == 1)
}
