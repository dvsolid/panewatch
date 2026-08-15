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
    /// Unlike `PaneDiscovery.parse` (where an empty `pane_title` is legitimate), both fields
    /// here must be non-empty: an attached client always has a real tty and a real session name.
    /// Without that check, a trailing-space line like `"/dev/ttys001 "` would slip past a naive
    /// `fields.count == 2` test and parse into a `ClientInfo` with an empty `sessionName` — which
    /// would make every *unattached* session look like it has a client attached at that tty.
    static func parse(_ output: String) throws -> [ClientInfo] {
        try output.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[0].isEmpty, !fields[1].isEmpty else {
                throw ClientDiscoveryError.malformedLine(String(line))
            }
            return ClientInfo(tty: String(fields[0]), sessionName: String(fields[1]))
        }
    }
}
