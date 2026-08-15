import Testing
@testable import TmuxCore

/// Exercises `SwitchActionPlanner.plan(target:attachedClient:)` — SPEC §4's "focus existing ->
/// open new -> fallback" priority ladder as a pure, fixture-testable decision, same discipline
/// as `AgentDetectorTests`'s classification-ladder coverage. No I/O, no real AppleScript
/// execution — the AppleScript sources built here are compile-checked separately with
/// `osacompile` against the real per-app dictionaries, not at test time (see this task's
/// Implementation notes).
@Suite struct SwitchActionPlannerTests {
    private let target = PaneTarget(paneId: "%51", sessionName: "ztest1", windowIndex: 2, paneIndex: 1)

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
}
