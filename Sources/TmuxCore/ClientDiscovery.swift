import Foundation

/// One attached tmux client, as reported by `list-clients` — parsing only, no resolution of
/// which app owns the tty (that's `TTYOwnerResolver`, TASK-017). Feature spec § Architecture.
public struct ClientInfo: Equatable, Sendable {
    public let tty: String
    public let sessionName: String
}

public enum ClientDiscoveryError: Error, Equatable {
    case malformedLine(String)
}

/// Turns one `list-clients` spawn into raw client records — mirrors `PaneDiscovery`'s role for
/// `list-panes`. Feature spec § Architecture (`ClientDiscovery`).
public struct ClientDiscovery: Sendable {
    private let gateway: any TmuxGateway

    public init(gateway: any TmuxGateway) {
        self.gateway = gateway
    }

    public func scan() throws -> [ClientInfo] {
        try Self.parse(gateway.listClients())
    }

    /// Parses `ProcessTmuxGateway.clientFormat`-shaped output: `tty session_name`, one attached
    /// client per line. `maxSplits: 1` on the space split is deliberate — `client_tty` never
    /// contains a space, but a session name can, so splitting on the *first* space only keeps a
    /// spaced session name intact instead of truncating it.
    ///
    /// A blank `tty` is skipped, not treated as malformed: `ControlModeActivitySource`'s pooled
    /// `tmux -C attach` clients (TASK-029) are real, correctly-attached tmux clients with a
    /// non-empty `client_session` but no backing pty, so `#{client_tty}` legitimately reports
    /// empty for them — live-verified against a real tmux server (` <session>`, leading space,
    /// one line per pooled control client, interleaved with real terminal clients in the same
    /// `list-clients` output). Switch's "focus existing" search (`SwitchActionPlanner`) only
    /// cares about clients backed by an actual terminal window, so these are simply not
    /// candidates — but they must not poison the *whole* scan the way throwing on this `.map`
    /// pass would: one skipped line here previously meant `try? clientDiscovery.scan()` at the
    /// call site saw `nil` and silently gave up on every session, not just this one, making
    /// double-click always fall through to "open new" the moment any control client was pooled.
    ///
    /// An empty `sessionName`, unlike `tty`, remains a genuine malformed-line signal: unlike
    /// `PaneDiscovery.parse` (where an empty `pane_title` is legitimate), every attached client —
    /// control-mode or not — always has a real session name. Without this check, a trailing-space
    /// line like `"/dev/ttys001 "` would slip past a naive `fields.count == 2` test and parse
    /// into a `ClientInfo` with an empty `sessionName` — which would make every *unattached*
    /// session look like it has a client attached at that tty.
    static func parse(_ output: String) throws -> [ClientInfo] {
        var clients: [ClientInfo] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[1].isEmpty else {
                throw ClientDiscoveryError.malformedLine(String(line))
            }
            guard !fields[0].isEmpty else { continue }
            clients.append(ClientInfo(tty: String(fields[0]), sessionName: String(fields[1])))
        }
        return clients
    }
}
