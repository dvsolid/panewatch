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

    /// Unused by any test in this file — required to conform to `TmuxGateway`.
    func listClients() throws -> String { "" }

    /// Unused by any test in this file — required to conform to `TmuxGateway`.
    func run(_ arguments: [String]) throws -> String { "" }
}

/// A stand-in `ActivitySource` that records whatever `onOutput` handler `StatusBarEngine.init`
/// wires up and lets a test fire it directly — this is the actual production path an agent's
/// output reaches `ActivityStateStore` through, so `phaseIsPreservedAcrossReconciliation` drives
/// it here rather than poking `ActivityStateStore` directly.
private final class FakeActivitySource: ActivitySource, @unchecked Sendable {
    var onOutput: ((String, Date) -> Void)?
    /// Records whatever `setWatchedPanes` last received, so a test can assert the pane-id ->
    /// session-name mapping `StatusBarEngine.reconcile()` builds (ADR-0004), not just that some
    /// call happened.
    private(set) var lastWatchedPanes: [String: String] = [:]
    func setWatchedPanes(_ panes: [String: String]) { lastWatchedPanes = panes }
    func fireOutput(paneId: String, at date: Date) { onOutput?(paneId, date) }
}

/// One `list-panes -a` raw-pane-line, `ProcessTmuxGateway.paneFormat`-shaped. Builds a minimal
/// controlled fixture line per pane rather than reusing `capturedPaneListFixture` — these tests
/// need to construct specific successive-pass scenarios (a pane present in one pass and absent
/// in the next), which a single frozen fixture can't express.
/// `windowActivity` (epoch seconds, `#{window_activity}`) defaults to a fixed moment far in the
/// past — tests that don't care about Activity Phase just need it present and parseable; tests
/// that do (the restart-seeding regression test below) pass an explicit value computed from
/// their own `now`.
private func paneLine(
    id: String,
    session: String = "sess",
    windowIndex: Int = 1,
    paneIndex: Int,
    command: String = "node",
    title: String,
    pid: Int32,
    windowActivity: TimeInterval = 1_700_000_000
) -> String {
    "\(id)|\(session)|\(windowIndex)|main|\(paneIndex)|\(command)|\(title)|\(pid)|/dev/ttys00\(paneIndex)|/path|0||0|\(windowActivity)"
}

private let claudeTaskOne = paneLine(id: "%1", paneIndex: 1, title: "✳ task-one", pid: 100)
private let claudeTaskThree = paneLine(id: "%3", paneIndex: 3, title: "✳ task-three", pid: 300)
private let piTaskTwo = paneLine(id: "%2", paneIndex: 2, command: "zsh", title: "π - proj", pid: 200)
/// A second, distinct session — `claudeTaskOne`/`claudeTaskThree`/`piTaskTwo` all default to
/// `session: "sess"`, which can't distinguish "the real session name" from "a hardcoded
/// placeholder" (ADR-0004's regression risk this task guards against).
private let claudeTaskFourInAnotherSession = paneLine(
    id: "%4", session: "wgt", paneIndex: 1, title: "✳ task-four", pid: 400
)

/// TASK-013: title matches are now corroborated against a live agent descendant every
/// `classify()` pass, so `AgentDetector`'s default `ProcessTableDescendantInspector` (a real
/// `ps` walk) would find none of these synthetic pids and silently exclude every Tile these
/// tests expect. Stands in a live descendant of the matching type for each fixture pane, same
/// as `AgentDetectorTests`' shared default fake.
private let fakeDescendantInspector = FakeDescendantProcessInspector(argvByPID: [
    100: ["/usr/local/bin/claude"], // %1
    200: ["/usr/local/bin/pi"], // %2
    300: ["/usr/local/bin/claude"], // %3
    400: ["/usr/local/bin/claude"] // %4
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

/// Bug repro: restarting the app wipes `ActivityStateStore`'s in-memory map, so the very first
/// `reconcile()` after a relaunch has no `lastOutputAt` record for any pane — including one that
/// was actively producing output seconds before the restart. An earlier fix attempt seeded a
/// freshly-discovered pane's `lastOutputAt` to `now`, but only on reconcile passes *after* an
/// established baseline, specifically to avoid painting every pre-existing pane green on the
/// very first pass — which left that very first pass, i.e. every app restart, exactly as broken
/// as before. The real fix: seed from tmux's own `#{window_activity}`
/// (`AgentPane.windowActivityAt`) instead of `now`. That timestamp is tracked by the tmux server
/// across this app's restarts, so `%1` (active 15s before this "restart") correctly reads
/// `.ready` on the very first reconcile, while `%2` (idle 2 hours) correctly still reads `.idle`
/// — the discrimination `now`-seeding on the first pass would have destroyed.
@Test func firstReconcileAfterRestartReflectsTmuxsOwnActivityTimestamp() throws {
    let now = Date()
    // Two *different* windows (`window_activity` is window-scoped in real tmux — every pane in
    // the same window reports the identical epoch, live-verified — so a test asserting different
    // seeded phases must put them in different windows, or it isn't modeling anything tmux can
    // actually produce).
    let recentlyActiveLine = paneLine(
        id: "%1", windowIndex: 1, paneIndex: 1, title: "✳ task-one", pid: 100,
        windowActivity: now.addingTimeInterval(-15).timeIntervalSince1970
    )
    let longIdleLine = paneLine(
        id: "%2", windowIndex: 2, paneIndex: 1, command: "zsh", title: "π - proj", pid: 200,
        windowActivity: now.addingTimeInterval(-7200).timeIntervalSince1970
    )
    let gateway = FakeTmuxGateway(output: [recentlyActiveLine, longIdleLine].joined(separator: "\n"))
    let engine = makeEngine(gateway: gateway)

    let firstPass = try engine.reconcile(now: now)

    #expect(firstPass.first { $0.id == "%1" }?.phase == .ready)
    #expect(firstPass.first { $0.id == "%2" }?.phase == .idle)
}

/// Bug repro (the EPIC-005-adjacent report this task fixes): `window_activity` is tracked per
/// *window*, not per pane — live-verified against a real tmux 3.6a server, every pane sharing a
/// window (e.g. two agent panes side by side, or an agent pane next to a plain shell the user is
/// typing in) reports the identical epoch. Seeding straight from it per pane, as the previous fix
/// did, means any pane whose window has a sibling inherits that sibling's activity as its own —
/// on a fresh app start, a pane genuinely idle for hours reads as freshly active just because
/// something else happened in the same tmux window. The fix: only trust `window_activity` to
/// seed a pane when that pane is alone in its window — the one case where the window's timestamp
/// and the pane's own timestamp are provably the same thing. A pane with a sibling starts `.idle`
/// instead, self-correcting on its own first real output rather than showing a false positive
/// that never corrects until that specific pane happens to produce output.
@Test func paneSharingAWindowIsNotFalselySeededByASiblingsActivity() throws {
    let now = Date()
    let recentActivity = now.addingTimeInterval(-15).timeIntervalSince1970
    // %1: a genuinely idle-for-hours agent pane, sharing window 1 with %2, a plain shell that
    // just produced output — tmux reports the same recent `window_activity` for both, since it's
    // the window's timestamp, not either pane's individually.
    let idleAgentSharingWindow = paneLine(
        id: "%1", windowIndex: 1, paneIndex: 1, title: "π - proj", pid: 100,
        windowActivity: recentActivity
    )
    let busyShellSibling = paneLine(
        id: "%2", windowIndex: 1, paneIndex: 2, command: "zsh", title: "", pid: 200,
        windowActivity: recentActivity
    )
    // %3: a second agent, alone in its own window 2, with the same recent `window_activity` —
    // the control: a solo pane's timestamp is trustworthy and should still seed normally.
    let soloAgent = paneLine(
        id: "%3", windowIndex: 2, paneIndex: 1, title: "✳ task-three", pid: 300,
        windowActivity: recentActivity
    )
    let gateway = FakeTmuxGateway(
        output: [idleAgentSharingWindow, busyShellSibling, soloAgent].joined(separator: "\n")
    )
    let engine = makeEngine(gateway: gateway)

    let firstPass = try engine.reconcile(now: now)

    #expect(firstPass.first { $0.id == "%1" }?.phase == .idle)
    #expect(firstPass.first { $0.id == "%3" }?.phase == .ready)
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

/// Acceptance item 3 (ADR-0004): `reconcile()` passes `activitySource.setWatchedPanes` the real
/// pane-id -> session-name mapping built from its `[AgentPane]` list, not a placeholder. Two
/// panes in two distinct sessions (`sess`, `wgt`) so a placeholder like an empty string or a
/// single hardcoded session name can't accidentally satisfy the assertion.
@Test func reconcilePassesRealSessionNamesToActivitySource() throws {
    let gateway = FakeTmuxGateway(
        output: [claudeTaskOne, claudeTaskFourInAnotherSession].joined(separator: "\n")
    )
    let activitySource = FakeActivitySource()
    let engine = makeEngine(gateway: gateway, activitySource: activitySource)

    _ = try engine.reconcile()

    #expect(activitySource.lastWatchedPanes == ["%1": "sess", "%4": "wgt"])
}
