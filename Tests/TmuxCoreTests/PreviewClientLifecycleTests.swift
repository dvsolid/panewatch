import Testing
@testable import TmuxCore

/// Records every `run(_:)` call it receives and lets a test script canned responses/failures
/// per exact argument vector — the seam that makes `PreviewClientLifecycle`'s sequencing and
/// failure-handling fixture-testable without spawning real tmux, mirroring `FakeTmuxGateway`
/// elsewhere in this suite (`PaneDiscoveryTests`, `StatusBarEngineTests`,
/// `PollingActivitySourceTests`) but scripted by argument vector rather than a fixed pane set,
/// since `PreviewClientLifecycle` issues several different one-shot commands in sequence.
private final class ScriptedTmuxGateway: TmuxGateway, @unchecked Sendable {
    struct CommandFailed: Error, Equatable { let arguments: [String] }

    private(set) var calls: [[String]] = []
    /// Argument vectors (joined by a single space) that should throw instead of succeeding.
    var failing: Set<String> = []
    /// Canned stdout per argument vector (joined by a single space); anything not present
    /// returns "".
    var responses: [String: String] = [:]

    func listPanes() throws -> String { "" }
    func capturePane(_ paneId: String) throws -> String { "" }

    func run(_ arguments: [String]) throws -> String {
        calls.append(arguments)
        let key = arguments.joined(separator: " ")
        if failing.contains(key) {
            throw CommandFailed(arguments: arguments)
        }
        return responses[key] ?? ""
    }

    func setResponse(_ output: String, for arguments: [String]) {
        responses[arguments.joined(separator: " ")] = output
    }

    func fail(_ arguments: [String]) {
        failing.insert(arguments.joined(separator: " "))
    }
}

/// Exercises `PreviewClientLifecycle`'s sequencing over a fake `TmuxGateway` — the pure
/// orchestration this task pulled out of the AppKit-facing `PreviewClient` (TmuxerApp)
/// specifically so it stays unit-testable. See `PreviewClientInvocation`'s doc comment for
/// the live-tmux findings that shaped this sequence.
@Suite struct PreviewClientLifecycleTests {
    private let paneID = "%51"
    private let groupName = "tmuxer-preview-51"

    private func makeGatewayWithExistingPane(windowIndex: Int = 2) -> ScriptedTmuxGateway {
        let gateway = ScriptedTmuxGateway()
        gateway.setResponse(
            "%51 \(windowIndex)",
            for: PreviewClientInvocation.paneLookupArguments(paneID: paneID)
        )
        return gateway
    }

    @Test func prepareGroupSessionRunsStepsInOrderAndReturnsTheGroupName() throws {
        let gateway = makeGatewayWithExistingPane(windowIndex: 2)
        let lifecycle = PreviewClientLifecycle(gateway: gateway)

        let result = try lifecycle.prepareGroupSession(paneID: paneID)

        #expect(result == groupName)
        #expect(gateway.calls == [
            PreviewClientInvocation.paneLookupArguments(paneID: paneID),
            PreviewClientInvocation.killGroupArguments(groupName: groupName),
            PreviewClientInvocation.createGroupArguments(paneID: paneID, groupName: groupName),
            PreviewClientInvocation.selectWindowArguments(groupName: groupName, windowIndex: 2),
            PreviewClientInvocation.selectPaneArguments(paneID: paneID)
        ])
    }

    /// Guards the phantom-session hazard directly: `new-session -t <bogus-pane>` does not
    /// fail on its own (verified live), so the pane-existence check must run first and must
    /// actually stop the sequence — nothing past `list-panes` may run for a dead pane.
    @Test func prepareGroupSessionThrowsAndCreatesNothingWhenPaneDoesNotExist() throws {
        let gateway = ScriptedTmuxGateway()
        gateway.fail(PreviewClientInvocation.paneLookupArguments(paneID: paneID))
        let lifecycle = PreviewClientLifecycle(gateway: gateway)

        #expect(throws: (any Error).self) {
            try lifecycle.prepareGroupSession(paneID: paneID)
        }
        #expect(gateway.calls == [PreviewClientInvocation.paneLookupArguments(paneID: paneID)])
    }

    /// `list-panes -t <pane>` resolves to the pane's *window* and can list multiple rows
    /// (verified live for a split window) — the lookup must pick the row matching the exact
    /// pane id, not just the first line.
    @Test func prepareGroupSessionPicksTheMatchingRowWhenTheWindowHasMultiplePanes() throws {
        let gateway = ScriptedTmuxGateway()
        gateway.setResponse(
            "%50 1\n%51 2",
            for: PreviewClientInvocation.paneLookupArguments(paneID: paneID)
        )
        let lifecycle = PreviewClientLifecycle(gateway: gateway)

        _ = try lifecycle.prepareGroupSession(paneID: paneID)

        #expect(gateway.calls.contains(
            PreviewClientInvocation.selectWindowArguments(groupName: groupName, windowIndex: 2)
        ))
    }

    /// The pre-cleanup `kill-session` is best-effort — a first-ever preview for a pane has no
    /// stale group to clean up, so this must not abort the sequence.
    @Test func prepareGroupSessionSurvivesAFailedStaleCleanup() throws {
        let gateway = makeGatewayWithExistingPane(windowIndex: 2)
        gateway.fail(PreviewClientInvocation.killGroupArguments(groupName: groupName))

        let lifecycle = PreviewClientLifecycle(gateway: gateway)
        let result = try lifecycle.prepareGroupSession(paneID: paneID)

        #expect(result == groupName)
    }

    /// A failure after the group session was created (e.g. `select-window` failing) must not
    /// leak that session — a reviewer can't see this working by reading `HoverPreviewController`,
    /// it only shows up as a `list-sessions` leak over time.
    @Test func prepareGroupSessionTearsDownAPartiallyCreatedGroupOnSelectWindowFailure() throws {
        let gateway = makeGatewayWithExistingPane(windowIndex: 2)
        gateway.fail(PreviewClientInvocation.selectWindowArguments(groupName: groupName, windowIndex: 2))
        let lifecycle = PreviewClientLifecycle(gateway: gateway)

        #expect(throws: (any Error).self) {
            try lifecycle.prepareGroupSession(paneID: paneID)
        }

        let killCalls = gateway.calls.filter { $0 == PreviewClientInvocation.killGroupArguments(groupName: groupName) }
        // Once for the pre-emptive stale-leftover cleanup, once more after the failure.
        #expect(killCalls.count == 2)
    }

    @Test func teardownGroupSessionIssuesKillSession() {
        let gateway = ScriptedTmuxGateway()
        let lifecycle = PreviewClientLifecycle(gateway: gateway)

        lifecycle.teardownGroupSession(groupName)

        #expect(gateway.calls == [PreviewClientInvocation.killGroupArguments(groupName: groupName)])
    }

    /// Teardown for a group session that never got created (prepare failed before step 3)
    /// must not throw or otherwise surface — `kill-session` on a nonexistent name just fails
    /// harmlessly and that failure is swallowed.
    @Test func teardownGroupSessionSwallowsFailureForANeverCreatedSession() {
        let gateway = ScriptedTmuxGateway()
        gateway.fail(PreviewClientInvocation.killGroupArguments(groupName: groupName))
        let lifecycle = PreviewClientLifecycle(gateway: gateway)

        lifecycle.teardownGroupSession(groupName)
    }
}
