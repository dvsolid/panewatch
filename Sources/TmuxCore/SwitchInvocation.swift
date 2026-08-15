/// Pure argument-vector/AppleScript builders for Switch's non-decision mechanics (TASK-020) —
/// the tmux-side retargeting SPEC §4 step 1 requires before `SwitchActionPlanner`'s AppleScript
/// runs (`SwitchActionPlanner.plan`'s own doc comment: that retargeting "is a separate command
/// dispatched by the caller"), and the open-a-new-terminal path for every branch that reaches it
/// (no attached client at all, an unsupported owning app, or a denied Automation permission on
/// the focus-existing path). Split out of `HoverPreviewController`'s AppKit-facing wiring the
/// same way `PreviewClientInvocation` is split out of `PreviewClientLifecycle`, so these vectors
/// stay assertable without spawning a process or an AppleScript runtime.
public enum SwitchInvocation {
    /// SPEC §4 step 1: retarget the tmux client already attached to the pane's session, before
    /// any AppleScript runs — never `attach` on this path (SPEC §4: "attach always creates an
    /// additional client"). Built from `sessionName:windowIndex`, never `window_name` alone
    /// (SPEC §3.4's dotted-window-name ambiguity applies here exactly as everywhere else a
    /// window target is built).
    public static func selectWindowArguments(target: PaneTarget) -> [String] {
        ["select-window", "-t", "\(target.sessionName):\(target.windowIndex)"]
    }

    public static func selectPaneArguments(target: PaneTarget) -> [String] {
        ["select-pane", "-t", target.paneId]
    }

    /// What "open a new terminal attached to the pane" (SPEC §4 path 2) means concretely — two
    /// different mechanisms depending on which app it targets: a subprocess launch for Ghostty
    /// (its own AppleScript dictionary has no verb to run a command in a new window — see
    /// `SwitchActionPlanner.ghosttyScript`'s doc comment), or an AppleScript for iTerm2/
    /// Terminal.app (both expose exactly that verb directly).
    public enum OpenNewAction: Equatable, Sendable {
        case launchProcess(executable: String, arguments: [String])
        case runScript(String)
    }

    /// `preferredApp` is the owning app already resolved for this pane's attached client, when
    /// there is one — used so a denied-Automation-permission fallback (acceptance item 3) still
    /// opens the terminal the user actually lives in, rather than a fixed default. `nil` when no
    /// client was attached at all (there's nothing to prefer), in which case Ghostty is the
    /// default — the only one of the three that opens with zero Automation-permission cost at
    /// all (a plain process launch, not AppleScript). See this task's `## Implementation` notes
    /// / decisions.md for why that default was chosen.
    public static func openNewAction(
        preferredApp: SupportedTerminalApp?,
        tmuxPath: String,
        paneId: String
    ) -> OpenNewAction {
        switch preferredApp {
        case .none, .ghostty:
            return .launchProcess(
                executable: "/usr/bin/open",
                // `-n`: force a new instance. Verified live (throwaway `task020-probe` tmux
                // session, this task's `## Implementation` notes) that without it, `open -a
                // Ghostty --args ...` silently activates Ghostty's already-running instance
                // and drops `--args` entirely once one is already running — the common case
                // on a dev machine — so no new window/attach ever happens.
                arguments: ["-n", "-a", "Ghostty", "--args", "-e", tmuxPath, "attach", "-t", paneId]
            )
        case .iTerm2:
            return .runScript("""
                tell application "iTerm2"
                    activate
                    create window with default profile command "\(tmuxPath) attach -t \(paneId)"
                end tell
                """)
        case .terminalApp:
            return .runScript("""
                tell application "Terminal"
                    activate
                    do script "\(tmuxPath) attach -t \(paneId)"
                end tell
                """)
        }
    }
}
