import Foundation

/// Wraps all tmux subprocess invocation. The only place a test can fake tmux — see CLAUDE.md
/// ("Tests must not depend on live tmux sessions") and feature spec § Architecture.
public protocol TmuxGateway: Sendable {
    /// Runs one `list-panes -a` spawn and returns its raw stdout. SPEC §2: never walk
    /// `list-sessions` → `list-windows` → `list-panes`; this is the single spawn that gets
    /// the whole topology.
    func listPanes() throws -> String

    /// Runs one `list-clients` spawn and returns its raw stdout — the only source of "which
    /// ttys have an attached tmux client right now." Feature spec § Architecture
    /// (`ClientDiscovery`): backs the Preview Client spawn decision and the Switch resolution
    /// path (TASK-016/TASK-018), same discipline as `listPanes` — one spawn, parsed by a
    /// dedicated module, never re-derived ad hoc at each call site.
    func listClients() throws -> String

    /// Captures one pane's visible screen. SPEC §3.1/§3.3: `-p -J`, and never `-S` — passing
    /// `-S` reads the normal screen's stale scrollback instead of the active alternate screen
    /// under an agent, making a busy pane look permanently idle (a real misdiagnosis SPEC §3.3
    /// corrects).
    func capturePane(_ paneId: String) throws -> String

    /// Runs one administrative one-shot tmux subcommand and returns its stdout, throwing on a
    /// non-zero exit — the same discipline as `listPanes`/`capturePane`, but for commands
    /// (`new-session`, `select-window`, `kill-session`, ...) that don't need a dedicated
    /// parsing method of their own. Backs the Preview Client's grouped-session lifecycle (see
    /// `PreviewClientLifecycle`, `PreviewClientInvocation`, TASK-015) — the tmux binary is
    /// still resolved via whatever `tmuxPath` the concrete gateway was constructed with, so
    /// callers never need to (and never should) pass a bare command string here.
    func run(_ arguments: [String]) throws -> String
}

/// The live `TmuxGateway`: shells out to the tmux binary resolved at `tmuxPath`, by absolute
/// path, never a bare `tmux` (SPEC §6 — the user's interactive `tmux` is a zsh plugin alias
/// that fails to resolve non-interactively).
public struct ProcessTmuxGateway: TmuxGateway {
    /// Full field list from feature spec §2, plus `window_activity` (epoch seconds of the
    /// window's last output — tracked by the tmux server itself, independent of this app's own
    /// process lifetime). Includes columns `PaneDiscovery` doesn't parse yet (`window_name`,
    /// `pane_current_path`, `session_grouped`, `session_group`, `alternate_on`) so later tasks
    /// (session-group dedup, alternate-screen handling) don't need to touch this format string
    /// again.
    static let paneFormat = [
        "#{pane_id}", "#{session_name}", "#{window_index}", "#{window_name}",
        "#{pane_index}", "#{pane_current_command}", "#{pane_title}", "#{pane_pid}",
        "#{pane_tty}", "#{pane_current_path}", "#{session_grouped}", "#{session_group}",
        "#{alternate_on}", "#{window_activity}"
    ].joined(separator: "|")

    /// Feature spec § Architecture (`ClientDiscovery`): space-delimited, not pipe-delimited
    /// like `paneFormat` — `list-clients` has only two fields and the spec's interface comment
    /// fixes this exact string.
    static let clientFormat = "#{client_tty} #{client_session}"

    public let tmuxPath: String

    public init(tmuxPath: String = TmuxCore.defaultTmuxPath) {
        self.tmuxPath = tmuxPath
    }

    public func listPanes() throws -> String {
        try Self.run(Self.listPanesInvocation(tmuxPath: tmuxPath))
    }

    public func listClients() throws -> String {
        try Self.run(Self.listClientsInvocation(tmuxPath: tmuxPath))
    }

    public func capturePane(_ paneId: String) throws -> String {
        try Self.run(Self.capturePaneInvocation(tmuxPath: tmuxPath, paneId: paneId))
    }

    public func run(_ arguments: [String]) throws -> String {
        try Self.run((tmuxPath, arguments))
    }

    /// Extracted so tests can assert on the exact argument vector without spawning a real
    /// process — the acceptance requirement is that tmux is never invoked bare, which means
    /// checking the executable slot and argument list, not just the path string.
    static func listPanesInvocation(tmuxPath: String) -> (executable: String, arguments: [String]) {
        (tmuxPath, ["list-panes", "-a", "-F", paneFormat])
    }

    /// Same never-bare-tmux discipline as `listPanesInvocation`; no `-t` — `list-clients`
    /// without a target lists every attached client server-wide, which is what
    /// `ClientDiscovery` needs (SPEC.md: never walk session-by-session).
    static func listClientsInvocation(tmuxPath: String) -> (executable: String, arguments: [String]) {
        (tmuxPath, ["list-clients", "-F", clientFormat])
    }

    /// SPEC §3.3: `-p -J` (visible screen, joined-wrapped lines), no `-S` — see the protocol
    /// doc comment on `capturePane`.
    static func capturePaneInvocation(tmuxPath: String, paneId: String) -> (executable: String, arguments: [String]) {
        (tmuxPath, ["capture-pane", "-t", paneId, "-p", "-J"])
    }

    struct CommandFailed: Error {
        let terminationStatus: Int32
    }

    /// Throws on a non-zero exit rather than trusting whatever landed on stdout — the same
    /// discipline `ProcessTableDescendantInspector.snapshotProcessTable` uses for `ps`. Without
    /// this, a pane that closes between a discovery scan and the next `capture-pane` probe (a
    /// routine race, not a rare edge case) makes tmux exit non-zero, and this silently returned
    /// its empty stdout as if the pane were genuinely blank instead of gone.
    ///
    /// `standardError` is explicitly discarded (`.nullDevice`), not left unset: `Process`
    /// inherits the parent's stderr by default, so tmux's own error text (e.g. `can't find
    /// pane: %81`) would otherwise leak straight into whatever terminal or log is watching this
    /// app's stderr — a real, user-visible symptom of the same missing-pane race this throw
    /// fixes. Callers already treat a thrown error as "skip this pane/pass" (`PollingActivitySource`
    /// via `try?`, `StatusBarEngine.reconcile` via `throws`), so the failure is handled, never
    /// printed.
    private static func run(_ invocation: (executable: String, arguments: [String])) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CommandFailed(terminationStatus: process.terminationStatus)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
