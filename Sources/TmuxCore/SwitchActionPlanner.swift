/// Identifies one pane as a Switch target — built from `#{window_index}`/`#{pane_index}`, never
/// `window_name` (SPEC §3.4: dotted window names make `window_name` ambiguous). Feature spec §
/// Architecture: `SwitchActionPlanner`.
public struct PaneTarget: Equatable, Sendable {
    public let paneId: String
    public let sessionName: String
    public let windowIndex: Int
    public let paneIndex: Int

    public init(paneId: String, sessionName: String, windowIndex: Int, paneIndex: Int) {
        self.paneId = paneId
        self.sessionName = sessionName
        self.windowIndex = windowIndex
        self.paneIndex = paneIndex
    }
}

/// The pane's attached tmux client, already resolved to its owning terminal app (or not) by
/// `TTYOwnerResolver` — `owningApp` is nil when the resolver walked the tty's ancestor chain and
/// found none of the three supported apps, distinct from "no client attached at all" (that case
/// is `SwitchActionPlanner.plan`'s `attachedClient: nil`, not a value of this type).
///
/// A struct with an `Optional` field, not a nested-optional tuple (`(tty: String,
/// SupportedTerminalApp?)?`) — this repo avoids double-optionals (see
/// `AgentDetector.DescendantWalkCache`'s doc comment for the same reasoning): "attached but
/// unresolved" and "not attached" need to stay two distinct, nameable states, and `plan`'s
/// three acceptance outcomes (openNew / focusExisting / openNew-as-fallback) each need a
/// distinct input to be genuinely falsifiable tests, not two tests hitting the same branch.
public struct AttachedClient: Equatable, Sendable {
    public let tty: String
    public let owningApp: SupportedTerminalApp?

    public init(tty: String, owningApp: SupportedTerminalApp?) {
        self.tty = tty
        self.owningApp = owningApp
    }
}

/// SPEC §4's click-behavior priority-ladder outcome: focus the terminal window/tab already
/// showing the pane's attached client, or open a new one. Deliberately does not cover SPEC §4's
/// third rung (a tooltip fallback showing the manual tmux command) — that's a
/// `HoverPreviewController` (TASK-020) presentation concern, not a planning decision.
///
/// Note: `focusExisting`'s `script` only selects the matching window/tab and activates the app
/// (ADR-002) — it does not run `select-window`/`select-pane` against the tmux session itself
/// (SPEC §4 step 1). That tmux-side retargeting is a separate command dispatched by the caller
/// (TASK-020's `HoverPreviewController`), not part of this pure decision.
public enum SwitchAction: Equatable, Sendable {
    case focusExisting(app: SupportedTerminalApp, script: String)
    case openNew(paneId: String)
}

/// Decides Switch's SPEC §4 priority-ladder outcome (focus existing -> open new) and, for the
/// focus-existing case, builds the per-app AppleScript source that selects the matching
/// window/tab and activates the app. Pure and fixture-testable — same discipline as
/// `AgentDetector`'s classification ladder — with no I/O of its own; actually running the
/// AppleScript is `AppleScriptRunner`'s job (TASK-019), and actually resolving
/// `attachedClient` is `ClientDiscovery`'s (TASK-016) plus `TTYOwnerResolver`'s (TASK-017).
public struct SwitchActionPlanner: Sendable {
    public init() {}

    public func plan(target: PaneTarget, attachedClient: AttachedClient?) -> SwitchAction {
        guard let attachedClient, let owningApp = attachedClient.owningApp else {
            return .openNew(paneId: target.paneId)
        }
        return .focusExisting(app: owningApp, script: Self.focusScript(app: owningApp, tty: attachedClient.tty))
    }

    /// Builds the per-app AppleScript source for the focus-existing case. Each app's script was
    /// hand-verified to compile against that app's real, installed scripting dictionary via
    /// `osacompile -o /dev/null` (not exercised in the test suite, which forbids real
    /// AppleScript execution — see this task's Implementation notes for the verification
    /// transcript and the exact `.sdef` terminology each branch relies on).
    private static func focusScript(app: SupportedTerminalApp, tty: String) -> String {
        switch app {
        case .ghostty: return ghosttyScript(tty: tty)
        case .iTerm2: return iTerm2Script(tty: tty)
        case .terminalApp: return terminalAppScript(tty: tty)
        }
    }

    /// Ghostty's scripting dictionary (`Ghostty.sdef`) exposes `window`/`tab`/`terminal`
    /// classes but no `tty` property on any of them — there is no term to search by. Falls back
    /// to activating the app only (still distinct from, and strictly better than, opening a
    /// brand-new terminal); the target tty is kept as a comment so the script still documents
    /// its intended target, per this task's acceptance criteria.
    private static func ghosttyScript(tty: String) -> String {
        """
        -- Ghostty's AppleScript dictionary has no tty-addressable window/terminal search
        -- (verified against Ghostty.sdef); falls back to activating the app only.
        -- target tty: \(tty)
        tell application "Ghostty"
            activate
        end tell
        """
    }

    /// iTerm2's `session` class exposes a read-only `tty` property (`iTerm2.sdef`), and
    /// `window`/`tab`/`session` each respond to the `select` command — so the exact session
    /// matching the target tty can be found and selected directly.
    private static func iTerm2Script(tty: String) -> String {
        """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    /// Terminal.app's `tab` class exposes a read-only `tty` property and a settable `selected`
    /// property (`Terminal.sdef`); its `window` class exposes a settable `frontmost` property.
    private static func terminalAppScript(tty: String) -> String {
        """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set frontmost of w to true
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }
}
