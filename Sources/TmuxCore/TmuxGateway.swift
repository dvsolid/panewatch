import Foundation

/// Wraps all tmux subprocess invocation. The only place a test can fake tmux — see CLAUDE.md
/// ("Tests must not depend on live tmux sessions") and feature spec § Architecture.
public protocol TmuxGateway: Sendable {
    /// Runs one `list-panes -a` spawn and returns its raw stdout. SPEC §2: never walk
    /// `list-sessions` → `list-windows` → `list-panes`; this is the single spawn that gets
    /// the whole topology.
    func listPanes() throws -> String
}

/// The live `TmuxGateway`: shells out to the tmux binary resolved at `tmuxPath`, by absolute
/// path, never a bare `tmux` (SPEC §6 — the user's interactive `tmux` is a zsh plugin alias
/// that fails to resolve non-interactively).
public struct ProcessTmuxGateway: TmuxGateway {
    /// Full field list from feature spec §2. Includes columns `PaneDiscovery` doesn't parse
    /// yet (`window_name`, `pane_current_path`, `session_grouped`, `session_group`,
    /// `alternate_on`) so later tasks (session-group dedup, alternate-screen handling) don't
    /// need to touch this format string again.
    static let paneFormat = "#{pane_id}|#{session_name}|#{window_index}|#{window_name}|#{pane_index}|#{pane_current_command}|#{pane_title}|#{pane_pid}|#{pane_tty}|#{pane_current_path}|#{session_grouped}|#{session_group}|#{alternate_on}"

    public let tmuxPath: String

    public init(tmuxPath: String = TmuxCore.defaultTmuxPath) {
        self.tmuxPath = tmuxPath
    }

    public func listPanes() throws -> String {
        let invocation = Self.listPanesInvocation(tmuxPath: tmuxPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Extracted so tests can assert on the exact argument vector without spawning a real
    /// process — the acceptance requirement is that tmux is never invoked bare, which means
    /// checking the executable slot and argument list, not just the path string.
    static func listPanesInvocation(tmuxPath: String) -> (executable: String, arguments: [String]) {
        (tmuxPath, ["list-panes", "-a", "-F", paneFormat])
    }
}
