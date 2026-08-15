import Testing
@testable import TmuxCore

/// Exercises `TerminalAppCatalog` — the single ordered registry of `TerminalAppProfile`s that
/// `TTYOwnerResolver`, `SwitchActionPlanner`, `SwitchInvocation`, and `HoverPreviewController`
/// all query instead of switching over `SupportedTerminalApp` independently (ADR-0003, TASK-021).
/// Mirrors `TTYOwnerResolverTests`' fixture style for the matcher, plus direct assertions on
/// each profile's `focusScript`/`openNewAction` output. This is the regression proof's
/// complement: `TTYOwnerResolverTests`/`SwitchActionPlannerTests`/`SwitchInvocationTests` prove
/// the re-pointed call sites still behave identically; these tests prove the catalog itself is
/// correct in isolation.
@Suite struct TerminalAppCatalogTests {
    // MARK: - match(basename:)

    @Test func matchResolvesGhosttyBasenameAndWrapsThePID() {
        let profile = TerminalAppCatalog.match(basename: "ghostty")

        #expect(profile?.makeApp(100) == .ghostty(pid: 100))
    }

    @Test func matchResolvesITerm2Basename() {
        let profile = TerminalAppCatalog.match(basename: "iterm2")

        #expect(profile?.makeApp(110) == .iTerm2(pid: 110))
    }

    @Test func matchResolvesTerminalAppBasename() {
        let profile = TerminalAppCatalog.match(basename: "terminal")

        #expect(profile?.makeApp(120) == .terminalApp(pid: 120))
    }

    @Test func matchResolvesCursorBasename() {
        let profile = TerminalAppCatalog.match(basename: "cursor")

        #expect(profile?.makeApp(140) == .cursor(pid: 140))
    }

    @Test func matchReturnsNilForAnUnrecognizedBasename() {
        #expect(TerminalAppCatalog.match(basename: "some-unrelated-launcher") == nil)
    }

    // MARK: - profile(for:).focusScript(...)

    private static let target = PaneTarget(paneId: "%51", sessionName: "ztest1", windowIndex: 2, paneIndex: 1, currentPath: "/Users/user/Projects/acme/ztest1")

    @Test func ghosttyProfileFocusScriptActivatesThenMatchesTitleThenWorkingDirectory() {
        let script = TerminalAppCatalog.profile(for: .ghostty(pid: 1)).focusScript(Self.target, "/dev/ttys030")

        #expect(script.contains("tell application \"Ghostty\""))
        #expect(script.contains("\"tmux attach -t ztest1\""))
        #expect(script.contains("\"/Users/user/Projects/acme/ztest1\""))
        #expect(script.contains("/dev/ttys030"))
    }

    @Test func iTerm2ProfileFocusScriptSelectsByTTY() {
        let script = TerminalAppCatalog.profile(for: .iTerm2(pid: 2)).focusScript(Self.target, "/dev/ttys030")

        #expect(script.contains("tell application \"iTerm2\""))
        #expect(script.contains("tty of s is \"/dev/ttys030\""))
    }

    @Test func terminalAppProfileFocusScriptSelectsByTTY() {
        let script = TerminalAppCatalog.profile(for: .terminalApp(pid: 3)).focusScript(Self.target, "/dev/ttys030")

        #expect(script.contains("tell application \"Terminal\""))
        #expect(script.contains("tty of t is \"/dev/ttys030\""))
    }

    /// Cursor ships no scripting dictionary — `activate` is the only verb available, so unlike
    /// the other three profiles there's no tab/window-level match clause to assert on. `tty` is
    /// still embedded (as a comment, see the profile's doc comment) for traceability.
    @Test func cursorProfileFocusScriptIsActivateOnly() {
        let script = TerminalAppCatalog.profile(for: .cursor(pid: 4)).focusScript(Self.target, "/dev/ttys030")

        #expect(script.contains("tell application \"Cursor\""))
        #expect(script.contains("activate"))
        #expect(script.contains("/dev/ttys030"))
    }

    // MARK: - profile(for:).openNewAction

    @Test func ghosttyProfileOpenNewActionLaunchesANewInstance() {
        let action = TerminalAppCatalog.profile(for: .ghostty(pid: 1)).openNewAction?("/opt/homebrew/bin/tmux", "%51")

        #expect(action == .launchProcess(
            executable: "/usr/bin/open",
            arguments: ["-n", "-a", "Ghostty", "--args", "-e", "/opt/homebrew/bin/tmux", "attach", "-t", "%51"]
        ))
    }

    @Test func iTerm2ProfileOpenNewActionRunsAScriptCarryingTheAttachCommand() {
        guard case .runScript(let script) = TerminalAppCatalog.profile(for: .iTerm2(pid: 2)).openNewAction?("/opt/homebrew/bin/tmux", "%51") else {
            Issue.record("expected .runScript")
            return
        }
        #expect(script.contains("tell application \"iTerm2\""))
        #expect(script.contains("/opt/homebrew/bin/tmux attach -t %51"))
    }

    @Test func terminalAppProfileOpenNewActionRunsAScriptCarryingTheAttachCommand() {
        guard case .runScript(let script) = TerminalAppCatalog.profile(for: .terminalApp(pid: 3)).openNewAction?("/opt/homebrew/bin/tmux", "%51") else {
            Issue.record("expected .runScript")
            return
        }
        #expect(script.contains("tell application \"Terminal\""))
        #expect(script.contains("/opt/homebrew/bin/tmux attach -t %51"))
    }

    /// The load-bearing property of the whole Cursor profile: `nil` here is what makes
    /// `SwitchInvocation.openNewAction`'s fallback fire for `.cursor` instead of crashing on a
    /// force-unwrap or scripting a mechanism that doesn't exist. Asserted directly so a future
    /// change that accidentally supplies an `openNewAction:` for Cursor fails a test at the
    /// catalog level, not silently downstream.
    @Test func cursorProfileHasNoOpenNewAction() {
        #expect(TerminalAppCatalog.profile(for: .cursor(pid: 4)).openNewAction == nil)
    }

    // MARK: - defaultOpenNewApp(isGhosttyAvailable:)

    @Test func defaultOpenNewAppIsGhosttyWhenAvailable() {
        #expect(TerminalAppCatalog.defaultOpenNewApp(isGhosttyAvailable: { true }) == .ghostty(pid: -1))
    }

    @Test func defaultOpenNewAppFallsBackToTerminalAppWhenGhosttyUnavailable() {
        #expect(TerminalAppCatalog.defaultOpenNewApp(isGhosttyAvailable: { false }) == .terminalApp(pid: -1))
    }

    // MARK: - resolveOpenNewApp(preferred:isGhosttyAvailable:)
    //
    // This is what `HoverPreviewController.resolveOpenNewPreferredApp` used to compute via its
    // own exhaustive switch over `SupportedTerminalApp` before the whole-branch review finding
    // that centralized it here — these tests are the regression proof that moving it didn't
    // change any of its four branches' behavior.

    @Test func resolveOpenNewAppFallsBackToDefaultWhenNoPreference() {
        #expect(TerminalAppCatalog.resolveOpenNewApp(preferred: nil, isGhosttyAvailable: { true }) == .ghostty(pid: -1))
        #expect(TerminalAppCatalog.resolveOpenNewApp(preferred: nil, isGhosttyAvailable: { false }) == .terminalApp(pid: -1))
    }

    /// Cursor's profile has no `openNewAction` at all — the case a bare "does its profile
    /// require an availability check" test wouldn't catch, since `requiresOpenNewAvailabilityCheck`
    /// is `false` for Cursor too. This is the fallback-when-no-mechanism branch the finding
    /// asked for explicitly.
    @Test func resolveOpenNewAppFallsBackToDefaultWhenPreferredHasNoOpenNewAction() {
        #expect(TerminalAppCatalog.resolveOpenNewApp(preferred: .cursor(pid: 4), isGhosttyAvailable: { true }) == .ghostty(pid: -1))
        #expect(TerminalAppCatalog.resolveOpenNewApp(preferred: .cursor(pid: 4), isGhosttyAvailable: { false }) == .terminalApp(pid: -1))
    }

    /// Ghostty has an `openNewAction` but its profile sets `requiresOpenNewAvailabilityCheck`
    /// — a stale/unverified preference for it must still be re-validated, so it routes through
    /// the default rather than passing through with its original pid.
    @Test func resolveOpenNewAppRoutesGhosttyPreferenceThroughTheAvailabilityCheckedDefault() {
        #expect(TerminalAppCatalog.resolveOpenNewApp(preferred: .ghostty(pid: 99), isGhosttyAvailable: { true }) == .ghostty(pid: -1))
        #expect(TerminalAppCatalog.resolveOpenNewApp(preferred: .ghostty(pid: 99), isGhosttyAvailable: { false }) == .terminalApp(pid: -1))
    }

    /// iTerm2/Terminal.app preferences pass through unpreferred apps that have an
    /// `openNewAction` and don't require re-validating availability — they're only ever set
    /// from an app `TTYOwnerResolver` already found running, so `isGhosttyAvailable` is never
    /// consulted for them, and the original pid is preserved.
    @Test func resolveOpenNewAppPassesThroughITerm2AndTerminalAppPreferencesUnchanged() {
        #expect(TerminalAppCatalog.resolveOpenNewApp(preferred: .iTerm2(pid: 7), isGhosttyAvailable: { true }) == .iTerm2(pid: 7))
        #expect(TerminalAppCatalog.resolveOpenNewApp(preferred: .terminalApp(pid: 8), isGhosttyAvailable: { true }) == .terminalApp(pid: 8))
    }
}
