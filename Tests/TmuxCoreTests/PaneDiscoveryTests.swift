import Foundation
import Testing
@testable import TmuxCore

/// Fakes `TmuxGateway` so `PaneDiscovery` tests never touch a live tmux server. Counts
/// `listPanes()` invocations so tests can assert the single-spawn discipline (SPEC §2).
private final class FakeTmuxGateway: TmuxGateway, @unchecked Sendable {
    let output: String
    private(set) var listPanesCallCount = 0

    init(output: String) {
        self.output = output
    }

    func listPanes() throws -> String {
        listPanesCallCount += 1
        return output
    }

    /// Unused by any test in this file — `PollingActivitySourceTests` exercises
    /// `capturePane` — but required to conform to `TmuxGateway`.
    func capturePane(_ paneId: String) throws -> String {
        ""
    }
}

/// A stand-in `ActivitySource` for tests that wire a `StatusBarEngine` but don't exercise
/// activity behavior — `StatusBarEngine.init` now requires a real `ActivitySource` (TASK-005),
/// and this file's tests care about discovery/label wiring, not phases.
private final class NoOpActivitySource: ActivitySource, @unchecked Sendable {
    var onOutput: ((String, Date) -> Void)?
    func setWatchedPanes(_ paneIds: Set<String>) {}
}

/// Every test wires the same fake-gateway-backed `PaneDiscovery`; only the spy test needs the
/// gateway itself afterward, hence returning both.
private func makeDiscovery(output: String = capturedPaneListFixture) -> (gateway: FakeTmuxGateway, discovery: PaneDiscovery) {
    let gateway = FakeTmuxGateway(output: output)
    return (gateway, PaneDiscovery(gateway: gateway))
}

/// Acceptance item 1: launching with tmux sessions running shows one Tile per pane that
/// actually exists. Exercised at the `PaneDiscovery.scan()` seam: one raw record per line,
/// with fields parsed correctly — including the empty-title row (`%28`), where
/// `omittingEmptySubsequences: false` on the field split is what keeps `pid`/`tty` aligned.
@Test func scanParsesOneRawPanePerLine() throws {
    let (_, discovery) = makeDiscovery()

    let panes = try discovery.scan()

    #expect(panes.count == 8)

    let plainShell = try #require(panes.first { $0.paneId == "%28" })
    #expect(plainShell.title == "")
    #expect(plainShell.sessionName == "billing-advisor")
    #expect(plainShell.command == "zsh")
    #expect(plainShell.pid == 8578)
    #expect(plainShell.tty == "/dev/ttys060")

    let pi = try #require(panes.first { $0.paneId == "%29" })
    #expect(pi.title == "π - rc-billing-advisor")
    #expect(pi.windowIndex == 1)
    #expect(pi.paneIndex == 2)

    let claude = try #require(panes.first { $0.paneId == "%9" })
    #expect(claude.title == "✳ task-execution-workflow")
    #expect(claude.command == "2.1.222")

    let grouped = try #require(panes.first { $0.paneId == "%51" })
    #expect(grouped.sessionName == "t2q")
    #expect(grouped.windowIndex == 1)
    #expect(grouped.paneIndex == 2)
    #expect(grouped.title == "✳ Investigate JIRA bug BZS-19252")
}

/// Acceptance item 2: each Tile's label is its raw `session:window.pane` identifier. `%51`'s
/// `window_name` is `2.1.228` (dotted); the label must come from `windowIndex`/`paneIndex`
/// instead (SPEC §3.4), so a correct label reads `t2q:1.2`, not something built from the
/// dotted `window_name`. Confirmed against this exact pane's real `list-panes -a` (no `-F`)
/// output: `t2q:1.2`. (Since TASK-003, `%51` also carries a Claude Code badge/task text —
/// those are asserted in `AgentDetectorTests`, not here; this test stays scoped to the label.)
@Test func tileLabelIsSessionWindowPaneBuiltFromIndices() throws {
    let (_, discovery) = makeDiscovery()
    let engine = StatusBarEngine(discovery: discovery, activitySource: NoOpActivitySource())

    let tiles = try engine.scanTiles()

    let dotted = try #require(tiles.first { $0.id == "%51" })
    #expect(dotted.label == "t2q:1.2")
}

/// Acceptance item 3: tmux is invoked only via `TmuxGateway`, by resolved absolute path —
/// never a bare `tmux`. Asserts the actual argument vector `ProcessTmuxGateway` builds
/// (executable slot vs. arguments), not just that the path string looks absolute — that's
/// the check that would catch a regression to something like `/bin/sh -c "tmux list-panes"`.
@Test func processGatewayNeverInvokesBareTmux() {
    let invocation = ProcessTmuxGateway.listPanesInvocation(tmuxPath: "/opt/homebrew/bin/tmux")

    #expect(invocation.executable == "/opt/homebrew/bin/tmux")
    #expect(invocation.executable.hasPrefix("/"))
    #expect(invocation.arguments == ["list-panes", "-a", "-F", ProcessTmuxGateway.paneFormat])
}

/// SPEC §3.3: capture must never carry `-S` — that flag reads the normal screen's stale
/// scrollback under an active alternate screen, making a busy agent pane look permanently
/// idle. A real misdiagnosis already happened here once; guard the exact argument vector the
/// same way `processGatewayNeverInvokesBareTmux` guards `list-panes`, so a future "helpful"
/// `-S` addition fails a test instead of shipping quietly.
@Test func processGatewayCapturesVisibleScreenOnlyNeverScrollback() {
    let invocation = ProcessTmuxGateway.capturePaneInvocation(tmuxPath: "/opt/homebrew/bin/tmux", paneId: "%51")

    #expect(invocation.executable == "/opt/homebrew/bin/tmux")
    #expect(invocation.arguments == ["capture-pane", "-t", "%51", "-p", "-J"])
    #expect(!invocation.arguments.contains("-S"))
}

/// Acceptance item 4: `list-panes` is spawned exactly once per discovery pass — not once per
/// session or window. The fixture spans 4 distinct sessions and 2 windows within `qtc-auto`,
/// so this would catch a regression to the `list-sessions` → `list-windows` → `list-panes`
/// walk SPEC §2 explicitly forbids.
@Test func scanSpawnsListPanesExactlyOnce() throws {
    let (gateway, discovery) = makeDiscovery()

    _ = try discovery.scan()

    #expect(gateway.listPanesCallCount == 1)
}
