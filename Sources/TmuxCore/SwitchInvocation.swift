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
    /// `TerminalAppCatalog.ghostty`'s doc comment), or an AppleScript for iTerm2/Terminal.app
    /// (both expose exactly that verb directly).
    public enum OpenNewAction: Equatable, Sendable {
        case launchProcess(executable: String, arguments: [String])
        case runScript(String)
    }

    /// `preferredApp` is the owning app already resolved for this pane's attached client, when
    /// there is one — used so a denied-Automation-permission fallback (acceptance item 3) still
    /// opens the terminal the user actually lives in, rather than a fixed default. `nil` when no
    /// client was attached at all (there's nothing to prefer), in which case Ghostty is the
    /// default — the only one of the three that opens with zero Automation-permission cost at
    /// all (a plain process launch, not AppleScript). See TASK-020's `## Implementation` notes
    /// / decisions.md for why that default was chosen. Delegates the per-app mechanism to
    /// `TerminalAppCatalog` (ADR-0003) rather than switching independently.
    public static func openNewAction(
        preferredApp: SupportedTerminalApp?,
        tmuxPath: String,
        paneId: String
    ) -> OpenNewAction {
        let app = preferredApp ?? .ghostty(pid: -1)
        guard let build = TerminalAppCatalog.profile(for: app).openNewAction else {
            // No open-new mechanism for this app (e.g. Cursor, TASK-022) — fall through to the
            // default open-new target, same as "no client attached at all".
            return TerminalAppCatalog.ghostty.openNewAction!(tmuxPath, paneId)
        }
        return build(tmuxPath, paneId)
    }
}
