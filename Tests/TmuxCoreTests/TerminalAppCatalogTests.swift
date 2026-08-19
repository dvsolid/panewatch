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

    /// TASK-038: a tab opened with `tmux new-session -s <session>` (rather than `attach`) is
    /// titled literally that — live-confirmed this environment never overwrites it with tmux's
    /// own dynamic title-setting — so the attach-only title check never fired for it.
    @Test func ghosttyProfileFocusScriptAlsoMatchesANewSessionTitle() {
        let script = TerminalAppCatalog.profile(for: .ghostty(pid: 1)).focusScript(Self.target, "/dev/ttys030")

        #expect(script.contains("\"tmux new-session -s ztest1\""))
    }

    /// Same gap as above for the `-A` (attach-or-create) invocation's own frozen title.
    @Test func ghosttyProfileFocusScriptAlsoMatchesANewSessionDashATitle() {
        let script = TerminalAppCatalog.profile(for: .ghostty(pid: 1)).focusScript(Self.target, "/dev/ttys030")

        #expect(script.contains("\"tmux new-session -A -s ztest1\""))
    }

    /// The three title candidates must all be tried before the working-directory fallback —
    /// otherwise a coincidental cwd match could win over a more specific title match.
    @Test func ghosttyProfileFocusScriptTriesAllTitleCandidatesBeforeWorkingDirectory() throws {
        let script = TerminalAppCatalog.profile(for: .ghostty(pid: 1)).focusScript(Self.target, "/dev/ttys030")

        let attachTitleIndex = try #require(script.range(of: "\"tmux attach -t ztest1\"")).lowerBound
        let newSessionTitleIndex = try #require(script.range(of: "\"tmux new-session -s ztest1\"")).lowerBound
        let newSessionATitleIndex = try #require(script.range(of: "\"tmux new-session -A -s ztest1\"")).lowerBound
        let workingDirectoryIndex = try #require(script.range(of: "\"/Users/user/Projects/acme/ztest1\"")).lowerBound

        #expect(attachTitleIndex < newSessionTitleIndex)
        #expect(newSessionTitleIndex < newSessionATitleIndex)
        #expect(newSessionATitleIndex < workingDirectoryIndex)

        // Chained candidates must render as AppleScript's `else if`, not a bare `else` (which
        // fails to compile) — the substring check above only proves each candidate is present,
        // not that they're actually chained together correctly.
        #expect(script.contains("else if"))
    }

    // MARK: - symlinkAliasedCandidatePath(for:homeDirectory:homeChildren:resolveSymlink:)
    //
    // TASK-038: tmux's `pane_current_path` reports the *canonical* cwd, but Ghostty's own
    // `working directory` property reflects whatever `$PWD` the shell was actually `cd`'d
    // through — which stays unresolved when that path passed through a home-relative symlink
    // (e.g. `~/widgets` -> `~/Work/Projects/widgets`). This pure helper generates the alternate
    // candidate. Home-directory listing and symlink resolution are both injected — mirrors
    // `TmuxCore.resolveTmuxPath`'s injectable `isExecutableFile` — so these tests never touch
    // the real `$HOME`.

    @Test func symlinkAliasedCandidatePathSwapsTheResolvedPrefixForTheSymlinksOwnName() {
        let candidate = TerminalAppCatalog.symlinkAliasedCandidatePath(
            for: "/Users/user/Work/Projects/widgets/rc-widget",
            homeDirectory: "/Users/user",
            homeChildren: { _ in ["widgets", "Work"] },
            resolveSymlink: { path in path == "/Users/user/widgets" ? "/Users/user/Work/Projects/widgets" : nil }
        )

        #expect(candidate == "/Users/user/widgets/rc-widget")
    }

    @Test func symlinkAliasedCandidatePathHandlesAnExactMatchWithNoRemainder() {
        let candidate = TerminalAppCatalog.symlinkAliasedCandidatePath(
            for: "/Users/user/Work/Projects/widgets",
            homeDirectory: "/Users/user",
            homeChildren: { _ in ["widgets"] },
            resolveSymlink: { path in path == "/Users/user/widgets" ? "/Users/user/Work/Projects/widgets" : nil }
        )

        #expect(candidate == "/Users/user/widgets")
    }

    @Test func symlinkAliasedCandidatePathReturnsNilWhenNoChildSymlinkResolvesTowardCurrentPath() {
        let candidate = TerminalAppCatalog.symlinkAliasedCandidatePath(
            for: "/Users/user/Work/Projects/other/repo",
            homeDirectory: "/Users/user",
            homeChildren: { _ in ["widgets"] },
            resolveSymlink: { path in path == "/Users/user/widgets" ? "/Users/user/Work/Projects/widgets" : nil }
        )

        #expect(candidate == nil)
    }

    @Test func symlinkAliasedCandidatePathIgnoresChildrenThatAreNotSymlinks() {
        let candidate = TerminalAppCatalog.symlinkAliasedCandidatePath(
            for: "/Users/user/Work/Projects/widgets/rc-widget",
            homeDirectory: "/Users/user",
            homeChildren: { _ in ["widgets"] },
            resolveSymlink: { _ in nil }
        )

        #expect(candidate == nil)
    }

    /// A resolved target that's merely a string prefix of `currentPath` — not a real path-
    /// component boundary — must not match. Without component-wise comparison, resolved
    /// `.../widgets` would wrongly match `.../widgetsextra/repo`.
    @Test func symlinkAliasedCandidatePathRequiresAPathComponentBoundaryNotJustAStringPrefix() {
        let candidate = TerminalAppCatalog.symlinkAliasedCandidatePath(
            for: "/Users/user/Work/Projects/widgetsextra/repo",
            homeDirectory: "/Users/user",
            homeChildren: { _ in ["widgets"] },
            resolveSymlink: { path in path == "/Users/user/widgets" ? "/Users/user/Work/Projects/widgets" : nil }
        )

        #expect(candidate == nil)
    }

    // MARK: - ghosttyFocusScript's symlink-aliased working-directory candidate wiring

    /// Proves `ghosttyFocusScript` actually wires `symlinkAliasedCandidatePath`'s result into
    /// an additional working-directory candidate, not just that the pure helper computes one
    /// correctly in isolation.
    @Test func ghosttyFocusScriptAddsASymlinkAliasedWorkingDirectoryCandidateWhenOneResolves() {
        let script = TerminalAppCatalog.ghosttyFocusScript(
            sessionName: "wgt",
            currentPath: "/Users/user/Work/Projects/widgets/rc-widget",
            tty: "/dev/ttys030",
            homeDirectory: "/Users/user",
            homeChildren: { _ in ["widgets"] },
            resolveSymlink: { path in path == "/Users/user/widgets" ? "/Users/user/Work/Projects/widgets" : nil }
        )

        #expect(script.contains("\"/Users/user/Work/Projects/widgets/rc-widget\""))
        #expect(script.contains("\"/Users/user/widgets/rc-widget\""))
    }

    /// The canonical-path candidate must still be tried before the symlink-aliased one — the
    /// alias is an *additional* candidate, not a replacement.
    @Test func ghosttyFocusScriptTriesTheCanonicalWorkingDirectoryBeforeTheAliasedOne() throws {
        let script = TerminalAppCatalog.ghosttyFocusScript(
            sessionName: "wgt",
            currentPath: "/Users/user/Work/Projects/widgets/rc-widget",
            tty: "/dev/ttys030",
            homeDirectory: "/Users/user",
            homeChildren: { _ in ["widgets"] },
            resolveSymlink: { path in path == "/Users/user/widgets" ? "/Users/user/Work/Projects/widgets" : nil }
        )

        let canonicalIndex = try #require(script.range(of: "\"/Users/user/Work/Projects/widgets/rc-widget\"")).lowerBound
        let aliasedIndex = try #require(script.range(of: "\"/Users/user/widgets/rc-widget\"")).lowerBound
        #expect(canonicalIndex < aliasedIndex)
    }

    /// When no home-directory child resolves toward the pane's canonical path, the script must
    /// stay exactly as before — no dangling extra clause.
    @Test func ghosttyFocusScriptOmitsTheAliasedCandidateWhenNoSymlinkResolves() {
        let script = TerminalAppCatalog.ghosttyFocusScript(
            sessionName: "wgt",
            currentPath: "/Users/user/Work/Projects/widgets/rc-widget",
            tty: "/dev/ttys030",
            homeDirectory: "/Users/user",
            homeChildren: { _ in [] },
            resolveSymlink: { _ in nil }
        )

        #expect(script.contains("\"/Users/user/Work/Projects/widgets/rc-widget\""))
        #expect(!script.contains("\"/Users/user/widgets/rc-widget\""))
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
