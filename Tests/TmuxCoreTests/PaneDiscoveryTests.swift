import Testing
@testable import TmuxCore

/// `list-panes -a -F <ProcessTmuxGateway.paneFormat>` output captured from a live tmux 3.6a
/// server on the reference machine (SPEC.md's "Technical Findings" data, re-captured here).
/// Frozen as a literal string — tests never touch a live tmux server (CLAUDE.md).
///
/// Covers: plain-shell pane with an empty title (`%28`), Pi detected via `zsh` (`%29`) and
/// `node` (`%54`) commands, Claude Code (`%9`), a not-agent pane whose title is the machine
/// hostname (`%5`, `%11`), a second window within one session (`qtc-auto` windows 1 and 2),
/// and a grouped session (`t2q`) with a dotted `window_name` (`2.1.228`) on both its panes.
private let fixture = """
%28|billing-advisor|1|zsh|1|zsh||8578|/dev/ttys060|/Users/dmitryv/Work/Projects/billing/rc-billing-advisor|0||0
%29|billing-advisor|1|zsh|2|zsh|π - rc-billing-advisor|25236|/dev/ttys056|/Users/dmitryv/Work/Projects/billing/rc-billing-advisor|0||0
%54|qtc-auto|1|main|2|node|π - qtc-ops-automation|29302|/dev/ttys031|/Users/dmitryv/Work/Projects/billing/qtc-ops-automation|0||0
%9|qtc-auto|1|main|3|2.1.222|✳ task-execution-workflow|8569|/dev/ttys032|/Users/dmitryv/Work/Projects/billing/qtc-ops-automation|0||1
%11|qtc-auto|2|run|1|node|LMYG2LW3F|8870|/dev/ttys034|/Users/dmitryv/Work/Projects/billing/qtc-ops-automation/frontend|0||0
%5|ngrok|1|ngrok|1|ngrok|LMYG2LW3F|8224|/dev/ttys028|/Users/dmitryv/Work/Projects/billing/text2quote|0||0
%45|t2q|1|2.1.228|1|zsh||32244|/dev/ttys027|/Users/dmitryv/Work/Projects/billing/text2quote|1|t2q|0
%51|t2q|1|2.1.228|2|2.1.228|✳ Investigate JIRA bug BZS-19252|54430|/dev/ttys050|/Users/dmitryv/Work/Projects/billing/text2quote|1|t2q|0
"""

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
}

/// Every test wires the same fake-gateway-backed `PaneDiscovery`; only the spy test needs the
/// gateway itself afterward, hence returning both.
private func makeDiscovery(output: String = fixture) -> (gateway: FakeTmuxGateway, discovery: PaneDiscovery) {
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

/// Acceptance item 2: each Tile's label is its raw `session:window.pane` identifier — no
/// agent-type badge, no color state. `%51`'s `window_name` is `2.1.228` (dotted); the label
/// must come from `windowIndex`/`paneIndex` instead (SPEC §3.4), so a correct label reads
/// `t2q:1.2`, not something built from the dotted `window_name`. Confirmed against this
/// exact pane's real `list-panes -a` (no `-F`) output: `t2q:1.2`.
@Test func tileLabelIsSessionWindowPaneBuiltFromIndices() throws {
    let (_, discovery) = makeDiscovery()
    let engine = StatusBarEngine(discovery: discovery)

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

/// Acceptance item 4: `list-panes` is spawned exactly once per discovery pass — not once per
/// session or window. The fixture spans 4 distinct sessions and 2 windows within `qtc-auto`,
/// so this would catch a regression to the `list-sessions` → `list-windows` → `list-panes`
/// walk SPEC §2 explicitly forbids.
@Test func scanSpawnsListPanesExactlyOnce() throws {
    let (gateway, discovery) = makeDiscovery()

    _ = try discovery.scan()

    #expect(gateway.listPanesCallCount == 1)
}
