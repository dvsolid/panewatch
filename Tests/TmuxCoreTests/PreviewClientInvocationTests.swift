import Testing
@testable import TmuxCore

/// Covers `PreviewClientInvocation`'s pure argument-vector builders — the tmux commands
/// backing a Preview Client's grouped-session lifecycle (glossary "Preview Client",
/// TASK-015). Mirrors `PaneDiscoveryTests`' `processGatewayNeverInvokesBareTmux` /
/// `processGatewayCapturesVisibleScreenOnlyNeverScrollback` discipline: assert on the exact
/// argument vector without spawning a real process.
///
/// These vectors implement the grouped-session design TASK-015's own `## Implementation`
/// notes record as a `[REQ CHANGE]` — attaching directly to the pane (`tmux attach -t
/// <pane_id>`, the task's originally-specified target) was verified live to retarget the
/// pane's *source session's* shared current-window pointer on every hover. Every test below
/// guards a specific piece of that fix.
@Suite struct PreviewClientInvocationTests {
    @Test func groupSessionNameStripsThePaneSigil() {
        #expect(PreviewClientInvocation.groupSessionName(paneID: "%51") == "tmuxer-preview-51")
    }

    /// Guards the fix's most important property: the long-lived attach targets the *group*
    /// session, never the pane directly — that's what keeps it from retargeting the source
    /// session's current window. Also guards CLAUDE.md's "never invoke bare tmux" rule the
    /// same way `capturePaneInvocation`'s own test does, since this is the one vector handed
    /// straight to `LocalProcessTerminalView.startProcess(executable:args:)` outside the
    /// `TmuxGateway` seam.
    @Test func attachInvocationTargetsGroupSessionNeverBareTmux() {
        let invocation = PreviewClientInvocation.attachInvocation(
            tmuxPath: "/opt/homebrew/bin/tmux",
            groupName: "tmuxer-preview-51"
        )

        #expect(invocation.executable == "/opt/homebrew/bin/tmux")
        #expect(invocation.executable.hasPrefix("/"))
        #expect(invocation.arguments == ["attach", "-r", "-f", "read-only,ignore-size", "-t", "tmuxer-preview-51"])
    }

    /// `-t <pane_id>` (not a session name) — tmux resolves a pane id to its owning session for
    /// grouping, so pane_id stays the only input this whole flow needs (SPEC §3.4).
    @Test func createGroupArgumentsGroupsAgainstThePaneNotTheSession() {
        let arguments = PreviewClientInvocation.createGroupArguments(paneID: "%51", groupName: "tmuxer-preview-51")

        #expect(arguments == ["new-session", "-t", "%51", "-d", "-s", "tmuxer-preview-51"])
    }

    /// Explicit `<groupName>:<windowIndex>`, not a bare pane id — verified live that
    /// `select-window -t <pane_id>` resolves ambiguously (against whatever tmux considers the
    /// "current session" absent a client context) once the source session already has a real
    /// attached client, silently landing on neither the source nor the group.
    @Test func selectWindowArgumentsUseExplicitGroupAndIndexNeverABarePaneID() {
        let arguments = PreviewClientInvocation.selectWindowArguments(groupName: "tmuxer-preview-51", windowIndex: 2)

        #expect(arguments == ["select-window", "-t", "tmuxer-preview-51:2"])
    }

    @Test func selectPaneArgumentsTargetsThePaneDirectly() {
        #expect(PreviewClientInvocation.selectPaneArguments(paneID: "%51") == ["select-pane", "-t", "%51"])
    }

    @Test func killGroupArgumentsTargetsTheGroupSessionByName() {
        #expect(PreviewClientInvocation.killGroupArguments(groupName: "tmuxer-preview-51") == ["kill-session", "-t", "tmuxer-preview-51"])
    }

    /// `-t <pane_id>` for `list-panes` resolves to the pane's *window* and lists every pane in
    /// it (verified live: a window with a split pane returned multiple rows for one `-t`
    /// target) — the format must carry `#{pane_id}` alongside `#{window_index}` so
    /// `PreviewClientLifecycle` can pick the row that actually matches, not just the first line.
    @Test func paneLookupArgumentsRequestsBothPaneIDAndWindowIndex() {
        #expect(PreviewClientInvocation.paneLookupArguments(paneID: "%51") == ["list-panes", "-t", "%51", "-F", "#{pane_id} #{window_index}"])
    }
}
