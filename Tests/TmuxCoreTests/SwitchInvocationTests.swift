import Foundation
import Testing
@testable import TmuxCore

/// Covers `SwitchInvocation`'s pure argument-vector/AppleScript builders — Switch's
/// non-decision mechanics (TASK-020): the tmux-side retargeting SPEC §4 step 1 requires
/// before `SwitchActionPlanner`'s AppleScript runs (its own doc comment: that retargeting
/// "is a separate command dispatched by the caller"), and the open-a-new-terminal path for
/// every branch that reaches it. Mirrors `PreviewClientInvocationTests`' discipline: assert
/// on the exact vector/script text without spawning a process or an AppleScript runtime.
@Suite struct SwitchInvocationTests {
    private static let target = PaneTarget(paneId: "%51", sessionName: "wgt", windowIndex: 2, paneIndex: 1, currentPath: "/Users/user/Projects/acme/quotegen")

    /// SPEC §4 step 1's first command — built from `sessionName:windowIndex`, never a bare
    /// pane id or `window_name` (SPEC §3.4's dotted-window-name ambiguity).
    @Test func selectWindowArgumentsTargetsSessionAndWindowIndex() {
        #expect(SwitchInvocation.selectWindowArguments(target: Self.target) == ["select-window", "-t", "wgt:2"])
    }

    @Test func selectPaneArgumentsTargetsThePaneDirectly() {
        #expect(SwitchInvocation.selectPaneArguments(target: Self.target) == ["select-pane", "-t", "%51"])
    }

    /// No attached client at all (`preferredApp == nil`) defaults to Ghostty — the only one of
    /// the three supported apps that opens via a plain process launch, not AppleScript, so it
    /// costs no Automation-permission prompt at all. `-n` is load-bearing: verified live
    /// (throwaway `task020-probe` tmux session) that without it, `open -a Ghostty --args ...`
    /// silently activates Ghostty's already-running instance and drops `--args` entirely —
    /// the common case on a dev machine — so no new window/attach ever happens.
    @Test func openNewActionWithNoPreferredAppLaunchesGhosttyAsANewInstance() {
        let action = SwitchInvocation.openNewAction(preferredApp: nil, tmuxPath: "/opt/homebrew/bin/tmux", paneId: "%51")

        #expect(action == .launchProcess(
            executable: "/usr/bin/open",
            arguments: ["-n", "-a", "Ghostty", "--args", "-e", "/opt/homebrew/bin/tmux", "attach", "-t", "%51"]
        ))
    }

    @Test func openNewActionWithGhosttyPreferredAppMatchesTheNoPreferenceDefault() {
        let action = SwitchInvocation.openNewAction(preferredApp: .ghostty(pid: 999), tmuxPath: "/opt/homebrew/bin/tmux", paneId: "%51")

        #expect(action == .launchProcess(
            executable: "/usr/bin/open",
            arguments: ["-n", "-a", "Ghostty", "--args", "-e", "/opt/homebrew/bin/tmux", "attach", "-t", "%51"]
        ))
    }

    /// Cursor has no scriptable "open a new attached terminal" mechanism at all (TASK-022) —
    /// `TerminalAppCatalog.cursor.openNewAction` is `nil`, so this falls through to the same
    /// default as no-preference/Ghostty, never a Cursor-specific path.
    @Test func openNewActionWithCursorPreferredAppMatchesTheNoPreferenceDefault() {
        let action = SwitchInvocation.openNewAction(preferredApp: .cursor(pid: 999), tmuxPath: "/opt/homebrew/bin/tmux", paneId: "%51")

        #expect(action == .launchProcess(
            executable: "/usr/bin/open",
            arguments: ["-n", "-a", "Ghostty", "--args", "-e", "/opt/homebrew/bin/tmux", "attach", "-t", "%51"]
        ))
    }

    /// iTerm2 exposes a "run this command in a new window" scripting verb directly — no
    /// separate process-launch step needed first, unlike Ghostty (see
    /// `SwitchActionPlanner.ghosttyScript`'s doc comment on why Ghostty's own dictionary has
    /// no such verb).
    @Test func openNewActionWithITerm2PreferredAppRunsAScriptCarryingTheAttachCommand() {
        let action = SwitchInvocation.openNewAction(preferredApp: .iTerm2(pid: 999), tmuxPath: "/opt/homebrew/bin/tmux", paneId: "%51")

        guard case .runScript(let script) = action else {
            Issue.record("expected .runScript, got \(action)")
            return
        }
        #expect(script.contains("tell application \"iTerm2\""))
        #expect(script.contains("/opt/homebrew/bin/tmux attach -t %51"))
    }

    @Test func openNewActionWithTerminalAppPreferredAppRunsAScriptCarryingTheAttachCommand() {
        let action = SwitchInvocation.openNewAction(preferredApp: .terminalApp(pid: 999), tmuxPath: "/opt/homebrew/bin/tmux", paneId: "%51")

        guard case .runScript(let script) = action else {
            Issue.record("expected .runScript, got \(action)")
            return
        }
        #expect(script.contains("tell application \"Terminal\""))
        #expect(script.contains("/opt/homebrew/bin/tmux attach -t %51"))
    }

    /// TASK-036 acceptance item 2: the pane IDs a bare-pane-ID attach's replay blast radius
    /// covers — every pane sharing the target's session, including the target pane itself
    /// (muting it too is harmless, and avoids a special case), excluding a different session's
    /// panes entirely, even if that session shares the same session *group* name prefix.
    @Test func sessionMatePaneIdsReturnsExactlyTheTargetsSessionPanes() {
        let target = PaneTarget(paneId: "%51", sessionName: "wgt", windowIndex: 2, paneIndex: 1, currentPath: "/Users/user/Projects/acme/quotegen")
        let panes = [
            makeRawPane(paneId: "%51", sessionName: "wgt"),
            makeRawPane(paneId: "%52", sessionName: "wgt"),
            makeRawPane(paneId: "%60", sessionName: "wgt-2")
        ]

        #expect(SwitchInvocation.sessionMatePaneIds(of: target, in: panes) == ["%51", "%52"])
    }

    private func makeRawPane(paneId: String, sessionName: String) -> RawPane {
        RawPane(
            sessionName: sessionName,
            windowIndex: 2,
            paneIndex: 1,
            paneId: paneId,
            title: "",
            command: "node",
            pid: 54430,
            tty: "/dev/ttys051",
            currentPath: "/Users/user/Projects/acme/quotegen",
            windowActivityAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}
