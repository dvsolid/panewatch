import Foundation
import Testing
@testable import TmuxCore

/// `list-clients -F <ProcessTmuxGateway.clientFormat>` output — space-delimited `tty
/// session_name` per line, one line per *attached* client. Only two of the three sessions in
/// this fixture have a client attached (`widget-advisor` and `wgt`); `ops-auto` has none, which
/// is why it never appears as a line here at all — `list-clients` only ever reports attached
/// clients, it doesn't enumerate sessions and pad the unattached ones.
private let capturedClientListFixture = """
/dev/ttys056 widget-advisor
/dev/ttys050 wgt
"""

/// Fakes `TmuxGateway` so `ClientDiscovery` tests never touch a live tmux server — mirrors
/// `PaneDiscoveryTests`' `FakeTmuxGateway`.
private final class FakeTmuxGateway: TmuxGateway, @unchecked Sendable {
    let output: String
    private(set) var listClientsCallCount = 0

    init(output: String) {
        self.output = output
    }

    func listClients() throws -> String {
        listClientsCallCount += 1
        return output
    }

    /// Unused by any test in this file — required to conform to `TmuxGateway`.
    func listPanes() throws -> String { "" }

    /// Unused by any test in this file — required to conform to `TmuxGateway`.
    func capturePane(_ paneId: String) throws -> String { "" }

    /// Unused by any test in this file — required to conform to `TmuxGateway`.
    func run(_ arguments: [String]) throws -> String { "" }
}

@Suite struct ClientDiscoveryTests {
    private func makeDiscovery(output: String = capturedClientListFixture) -> (gateway: FakeTmuxGateway, discovery: ClientDiscovery) {
        let gateway = FakeTmuxGateway(output: output)
        return (gateway, ClientDiscovery(gateway: gateway))
    }

    /// Acceptance item 1: N attached clients in `list-clients` output produce N `ClientInfo`
    /// records with correct `tty`/`sessionName`.
    @Test func scanParsesOneClientInfoPerAttachedClient() throws {
        let (_, discovery) = makeDiscovery()

        let clients = try discovery.scan()

        #expect(clients.count == 2)
        #expect(clients.contains(ClientInfo(tty: "/dev/ttys056", sessionName: "widget-advisor")))
        #expect(clients.contains(ClientInfo(tty: "/dev/ttys050", sessionName: "wgt")))
    }

    /// Acceptance item 2: a session with no attached client must be correctly absent, not
    /// represented as a false empty-string match. `ops-auto` (in the fixture's implied topology)
    /// never appears — but the sharper regression this guards is a *blank line* in the output
    /// (e.g. a trailing newline after the last client) parsing into `ClientInfo(tty: "",
    /// sessionName: "")`, which would make every unattached session look like it has a client
    /// attached at tty `""`. `omittingEmptySubsequences: true` on the line split handles the
    /// trailing-newline case; the empty-output case must yield `[]`, never a phantom record.
    @Test func scanOnEmptyOutputReturnsNoClients() throws {
        let (_, discovery) = makeDiscovery(output: "")

        let clients = try discovery.scan()

        #expect(clients.isEmpty)
        #expect(!clients.contains { $0.tty.isEmpty || $0.sessionName.isEmpty })
    }

    /// Acceptance item 3: a malformed line is handled consistently with `PaneDiscovery`'s own
    /// error handling — throws a specific, equatable error rather than silently dropping the
    /// line or misparsing it. A line with no space at all has no way to separate tty from
    /// session name.
    @Test func scanThrowsOnLineWithNoSeparator() throws {
        let (_, discovery) = makeDiscovery(output: "garbage")

        #expect(throws: ClientDiscoveryError.malformedLine("garbage")) {
            try discovery.scan()
        }
    }

    /// A trailing-space line (`"/dev/ttys001 "`) would slip past a naive `fields.count == 2`
    /// check with an empty `sessionName` — an attached client always has a real session name, so
    /// this must also throw, not silently produce a `ClientInfo` that makes an unattached
    /// session look like it has a client.
    @Test func scanThrowsOnLineWithTrailingSpaceAndNoSessionName() throws {
        let (_, discovery) = makeDiscovery(output: "/dev/ttys001 ")

        #expect(throws: ClientDiscoveryError.malformedLine("/dev/ttys001 ")) {
            try discovery.scan()
        }
    }

    /// Bug repro (EPIC-005 regression): `ControlModeActivitySource`'s pooled `tmux -C attach`
    /// clients are real, attached tmux clients with no backing pty — `list-clients` reports them
    /// with a blank `client_tty` (live-verified: `" t2q"`, leading space, session name only), not
    /// as a malformed line. Before this fix, a blank tty threw on this `.map` pass, and since
    /// `try? clientDiscovery.scan()` at the Switch call site turns any throw into `nil`, *every*
    /// double-click's "focus existing window" search silently found nothing the moment any
    /// session had a pooled control client — which, once TASK-029 wired the real stack in, is
    /// effectively always. A blank-tty line must be skipped, and — the sharper regression this
    /// guards against — must not also swallow the real terminal clients sharing the same
    /// `list-clients` output.
    @Test func scanSkipsControlModeClientsWithBlankTTYWithoutLosingRealClients() throws {
        let (_, discovery) = makeDiscovery(output: [
            "/dev/ttys056 widget-advisor",
            " widget-advisor",
            "/dev/ttys050 wgt"
        ].joined(separator: "\n"))

        let clients = try discovery.scan()

        #expect(clients.count == 2)
        #expect(clients.contains(ClientInfo(tty: "/dev/ttys056", sessionName: "widget-advisor")))
        #expect(clients.contains(ClientInfo(tty: "/dev/ttys050", sessionName: "wgt")))
    }

    /// Slice: tmux is invoked only via `TmuxGateway`, by resolved absolute path — never a bare
    /// `tmux` (CLAUDE.md) — and `list-clients` must run server-wide, not `-t`-scoped to one
    /// session (SPEC.md: never walk session-by-session). Mirrors
    /// `PaneDiscoveryTests.processGatewayNeverInvokesBareTmux`.
    @Test func processGatewayNeverInvokesBareTmuxForListClients() {
        let invocation = ProcessTmuxGateway.listClientsInvocation(tmuxPath: "/opt/homebrew/bin/tmux")

        #expect(invocation.executable == "/opt/homebrew/bin/tmux")
        #expect(invocation.executable.hasPrefix("/"))
        #expect(invocation.arguments == ["list-clients", "-F", ProcessTmuxGateway.clientFormat])
        #expect(!invocation.arguments.contains("-t"))
    }
}
