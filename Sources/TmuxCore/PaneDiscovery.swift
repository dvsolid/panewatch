import Foundation

/// One tmux pane, as reported by `list-panes -a`, with no agent classification applied yet.
///
/// Deliberately does not carry `windowName`: SPEC §3.4 — dotted window names (`wgt:2.1.228`)
/// make `window_name` ambiguous as a target/label component, so display and click-targets are
/// always built from `windowIndex`/`paneIndex` instead. See feature spec § Architecture.
public struct RawPane: Equatable, Sendable {
    public let sessionName: String
    public let windowIndex: Int
    public let paneIndex: Int
    public let paneId: String
    public let title: String
    public let command: String
    public let pid: Int32
    public let tty: String
    /// `#{pane_current_path}` — the pane shell's current working directory. Used as
    /// `SwitchActionPlanner`'s fallback match when focusing an existing Ghostty window (its
    /// AppleScript dictionary exposes no `tty` property, see that type's `ghosttyScript` doc
    /// comment).
    public let currentPath: String
    /// tmux's own last-output timestamp for this pane's window (`#{window_activity}`),
    /// independent of this app's own process lifetime — the anchor `StatusBarEngine` seeds a
    /// pane's Activity Phase from the moment it's first discovered, including on the very first
    /// discovery pass after an app relaunch (see `ActivityStateStore.seedIfAbsent`).
    public let windowActivityAt: Date
}

public enum PaneDiscoveryError: Error, Equatable {
    case malformedLine(String)
}

/// Turns one `list-panes -a` spawn into raw pane records. Parsing only — no agent
/// classification (`AgentDetector`, TASK-003) and no session-group dedup.
public struct PaneDiscovery: Sendable {
    private let gateway: any TmuxGateway

    public init(gateway: any TmuxGateway) {
        self.gateway = gateway
    }

    public func scan() throws -> [RawPane] {
        try Self.parse(gateway.listPanes())
    }

    /// Parses `ProcessTmuxGateway.paneFormat`-shaped output: 14 `|`-delimited fields per
    /// line, matching `#{pane_id}|#{session_name}|#{window_index}|#{window_name}|
    /// #{pane_index}|#{pane_current_command}|#{pane_title}|#{pane_pid}|#{pane_tty}|
    /// #{pane_current_path}|#{session_grouped}|#{session_group}|#{alternate_on}|
    /// #{window_activity}`. Only the 9 fields `RawPane` declares are kept; the rest are
    /// reserved for later tasks.
    ///
    /// `omittingEmptySubsequences: false` on the field split matters: `pane_title` is
    /// routinely empty (untitled panes), and dropping empty subsequences would silently
    /// shift every field after it.
    static func parse(_ output: String) throws -> [RawPane] {
        try output.split(separator: "\n", omittingEmptySubsequences: true).map { line in
            let fields = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 14,
                  let windowIndex = Int(fields[2]),
                  let paneIndex = Int(fields[4]),
                  let pid = Int32(fields[7]),
                  let windowActivityEpoch = TimeInterval(fields[13])
            else {
                throw PaneDiscoveryError.malformedLine(String(line))
            }
            return RawPane(
                sessionName: fields[1],
                windowIndex: windowIndex,
                paneIndex: paneIndex,
                paneId: fields[0],
                title: fields[6],
                command: fields[5],
                pid: pid,
                tty: fields[8],
                currentPath: fields[9],
                windowActivityAt: Date(timeIntervalSince1970: windowActivityEpoch)
            )
        }
    }
}
