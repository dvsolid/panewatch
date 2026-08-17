import Testing
@testable import TmuxCore

/// Exercises `SwitchActionPlanner.plan(target:attachedClient:)` — SPEC §4's "focus existing ->
/// open new -> fallback" priority ladder as a pure, fixture-testable decision, same discipline
/// as `AgentDetectorTests`'s classification-ladder coverage. No I/O, no real AppleScript
/// execution — the AppleScript sources built here are compile-checked separately with
/// `osacompile` against the real per-app dictionaries, not at test time (see this task's
/// Implementation notes).
@Suite struct SwitchActionPlannerTests {
    private let target = PaneTarget(paneId: "%51", sessionName: "ztest1", windowIndex: 2, paneIndex: 1, currentPath: "/Users/user/Projects/acme/ztest1")

    @Test func noAttachedClientOpensNew() {
        let planner = SwitchActionPlanner()

        let action = planner.plan(target: target, attachedClient: nil)

        #expect(action == .openNew(paneId: "%51"))
    }

    @Test func attachedClientWithSupportedAppFocusesExisting() {
        let planner = SwitchActionPlanner()
        let client = AttachedClient(tty: "/dev/ttys022", owningApp: .iTerm2(pid: 110))

        let action = planner.plan(target: target, attachedClient: client)

        guard case .focusExisting(let app, let script) = action else {
            Issue.record("expected .focusExisting, got \(action)")
            return
        }
        #expect(app == .iTerm2(pid: 110))
        #expect(script.contains("/dev/ttys022"))
    }

    @Test func attachedClientWithUnresolvedOwningAppFallsBackToOpenNew() {
        // Mirrors a real caller: `TTYOwnerResolver.resolveOwningApp(tty:)` returned nil (the
        // tty's ancestor chain hit none of the three supported apps), but there *is* an
        // attached client — distinct from `noAttachedClientOpensNew`'s "no client at all".
        let planner = SwitchActionPlanner()
        let client = AttachedClient(tty: "/dev/ttys009", owningApp: nil)

        let action = planner.plan(target: target, attachedClient: client)

        #expect(action == .openNew(paneId: "%51"))
    }

    /// Each script's syntactic validity against its real app's scripting dictionary was
    /// verified once, out-of-band, via `osacompile -o /dev/null` against the actual installed
    /// `.sdef` files (Ghostty.sdef, iTerm2.sdef, Terminal.sdef on this dev machine) — recorded
    /// in this task's Implementation notes. This test only checks what a pure fixture test can:
    /// each app produces its own, distinct script naming that app and referencing the tty.
    @Test func eachSupportedAppProducesDistinctScriptReferencingTheApp() {
        let planner = SwitchActionPlanner()
        let tty = "/dev/ttys030"
        let apps: [(SupportedTerminalApp, expectedAppName: String)] = [
            (.ghostty(pid: 1), "Ghostty"),
            (.iTerm2(pid: 2), "iTerm2"),
            (.terminalApp(pid: 3), "Terminal"),
            (.cursor(pid: 4), "Cursor")
        ]

        let scripts = apps.map { app, expectedAppName -> String in
            let client = AttachedClient(tty: tty, owningApp: app)
            guard case .focusExisting(_, let script) = planner.plan(target: target, attachedClient: client) else {
                Issue.record("expected .focusExisting for \(app)")
                return ""
            }
            #expect(script.contains("tell application \"\(expectedAppName)\""))
            #expect(script.contains(tty))
            return script
        }

        #expect(Set(scripts).count == scripts.count)
    }

    /// Ghostty's script must `activate` the app unconditionally first — `focus` alone never
    /// raises Ghostty above other apps when it's in the background (this was the actual bug:
    /// double-clicking a Tile while Ghostty sat behind another app did nothing) — then try, in
    /// order, an exact title match against the tab's freshly-attached title, then a
    /// working-directory match. This only checks script *shape* (`activate` before both match
    /// clauses, both present, title before path) — the match actually working was verified live
    /// against the real, currently-installed Ghostty.
    @Test func ghosttyScriptActivatesFirstThenTriesTitleThenWorkingDirectory() throws {
        let planner = SwitchActionPlanner()
        let client = AttachedClient(tty: "/dev/ttys030", owningApp: .ghostty(pid: 1))

        guard case .focusExisting(_, let script) = planner.plan(target: target, attachedClient: client) else {
            Issue.record("expected .focusExisting")
            return
        }

        #expect(script.contains("\"tmux attach -t ztest1\""))
        #expect(script.contains("\"/Users/user/Projects/acme/ztest1\""))
        #expect(script.contains("activate"))
        let activateIndex = try #require(script.range(of: "activate"))
        let titleClauseIndex = try #require(script.range(of: "tmux attach -t ztest1"))
        let pathClauseIndex = try #require(script.range(of: "/Users/user/Projects/acme/ztest1"))
        #expect(activateIndex.lowerBound < titleClauseIndex.lowerBound)
        #expect(titleClauseIndex.lowerBound < pathClauseIndex.lowerBound)
    }

    /// Cursor ships no `.sdef` scripting dictionary (feature spec Further Notes,
    /// live-verified) — its focus script can only `activate` the app, unlike the other three
    /// apps' tab/window-level selection.
    @Test func attachedClientWithCursorFocusesExistingWithAnActivateOnlyScript() {
        let planner = SwitchActionPlanner()
        let client = AttachedClient(tty: "/dev/ttys033", owningApp: .cursor(pid: 4))

        let action = planner.plan(target: target, attachedClient: client)

        guard case .focusExisting(let app, let script) = action else {
            Issue.record("expected .focusExisting, got \(action)")
            return
        }
        #expect(app == .cursor(pid: 4))
        #expect(script.contains("tell application \"Cursor\""))
        #expect(script.contains("activate"))
    }

    /// A session name or path containing a double quote or backslash must not break out of the
    /// AppleScript string literal it's embedded in — this is the one input to this whole flow
    /// that isn't tightly formatted (unlike tty), so it's the one that needs escaping.
    @Test func ghosttyScriptEscapesQuotesAndBackslashesInSessionNameAndPath() {
        let planner = SwitchActionPlanner()
        let target = PaneTarget(
            paneId: "%99",
            sessionName: "weird\"name",
            windowIndex: 1,
            paneIndex: 1,
            currentPath: "/Users/user/back\\slash"
        )
        let client = AttachedClient(tty: "/dev/ttys031", owningApp: .ghostty(pid: 1))

        guard case .focusExisting(_, let script) = planner.plan(target: target, attachedClient: client) else {
            Issue.record("expected .focusExisting")
            return
        }

        #expect(script.contains("tmux attach -t weird\\\"name"))
        #expect(script.contains("/Users/user/back\\\\slash"))
    }
}
