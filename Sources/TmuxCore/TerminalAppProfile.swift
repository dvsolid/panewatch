/// The single per-app bundle of everything Switch needs to know about one Supported Terminal
/// App — how to recognize its process ancestry, how to focus it, and how (if at all) to open a
/// new attached terminal in it. A data struct of closures, not a protocol, per ADR-0003:
/// profiles stay data, not dispatch. See `TerminalAppCatalog` for the registry of these.
public struct TerminalAppProfile: Sendable {
    /// Executable basenames (lowercased) that identify this app in a process-ancestry walk —
    /// `TTYOwnerResolver`'s matcher checks these. A `Set` because a future app could ship more
    /// than one recognized executable name; every existing app has exactly one.
    public let processBasenames: Set<String>

    /// Wraps a matched ancestor pid into this app's `SupportedTerminalApp` identity case.
    public let makeApp: @Sendable (Int32) -> SupportedTerminalApp

    /// Builds the per-app AppleScript source that selects the matching window/tab and
    /// activates the app, for `SwitchActionPlanner`'s focus-existing case.
    public let focusScript: @Sendable (PaneTarget, _ tty: String) -> String

    /// Builds the mechanism to open a new terminal attached to a pane in this app. `nil` when
    /// this app can't be scripted to open a new attached terminal at all (e.g. Cursor,
    /// TASK-022) — the caller falls through to the default open-new target in that case.
    public let openNewAction: (@Sendable (_ tmuxPath: String, _ paneId: String) -> SwitchInvocation.OpenNewAction)?

    public init(
        processBasenames: Set<String>,
        makeApp: @escaping @Sendable (Int32) -> SupportedTerminalApp,
        focusScript: @escaping @Sendable (PaneTarget, String) -> String,
        openNewAction: (@Sendable (String, String) -> SwitchInvocation.OpenNewAction)? = nil
    ) {
        self.processBasenames = processBasenames
        self.makeApp = makeApp
        self.focusScript = focusScript
        self.openNewAction = openNewAction
    }
}
