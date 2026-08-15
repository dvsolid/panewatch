import Foundation
import Testing
@testable import TmuxCore

/// Exercises `ProcessTableDescendantInspector` itself (not the `FakeDescendantProcessInspector`
/// used by `AgentDetectorTests`) — specifically the failure-signal handling in
/// `snapshotProcessTable()`. Before this test file existed, nothing spawned a real subprocess
/// through this type, so a `ps` snapshot that runs but fails (non-zero exit, or a zero exit with
/// empty stdout) could regress silently: `descendantArgv(of:)` must return `[:]` (pid *absent*)
/// in that case, never `[pid: []]` (pid present, walked, found nothing) — see the
/// `DescendantProcessInspector` protocol doc comment for why the two are not interchangeable.
///
/// Each test writes a tiny fake `ps`-shaped shell script to a temp file and points the inspector
/// at it via the `psExecutableURL` test seam, the same pattern `ProcessTmuxGateway.tmuxPath`
/// uses (CLAUDE.md: "shell out through an injectable command runner so the real binary can be
/// faked").
@Suite struct DescendantProcessInspectorTests {
    /// Writes an executable shell script whose body is `body`, returning its file URL. Callers
    /// are responsible for nothing further — each test uses its own uniquely named temp file, so
    /// no cleanup coordination is needed across tests.
    private func makeFakePS(body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-ps-\(UUID().uuidString)")
        let script = "#!/bin/sh\n\(body)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func successfulSnapshotWalksDescendants() throws {
        // pid 100 is the requested pane pid; pid 200 is its child running `claude`.
        let ps = try makeFakePS(body: """
        echo '100 1 -zsh'
        echo '200 100 /usr/local/bin/claude'
        """)
        let inspector = ProcessTableDescendantInspector(psExecutableURL: ps)

        let result = inspector.descendantArgv(of: [100])

        #expect(result[100] == ["/usr/local/bin/claude"])
    }

    @Test func nonZeroExitFailsOpenRatherThanReportingAnEmptyWalk() throws {
        // Exits non-zero but still prints output that would otherwise parse cleanly — the
        // exact case a bare `try?` around `process.run()` cannot catch, since `run()` itself
        // never throws here. Only inspecting `terminationStatus` catches this.
        let ps = try makeFakePS(body: """
        echo '100 1 -zsh'
        echo '200 100 /usr/local/bin/claude'
        exit 1
        """)
        let inspector = ProcessTableDescendantInspector(psExecutableURL: ps)

        let result = inspector.descendantArgv(of: [100])

        // pid 100 must be ABSENT (walk-could-not-run), not present with an empty array
        // (walk-ran-found-nothing) — those two are the interpretations `AgentDetector`
        // must never confuse (fail-open keeps a title match / defers caching a fallback).
        #expect(result[100] == nil)
        #expect(result.isEmpty)
    }

    @Test func emptySuccessfulOutputFailsOpenRatherThanReportingAnEmptyWalk() throws {
        // Exits 0 (success) but with no process-table rows at all — the belt-and-suspenders
        // case: a real `ps -A` on macOS always reports at least `launchd` and `ps` itself, so
        // zero rows after a "successful" run is itself a reasonable failure signal.
        let ps = try makeFakePS(body: "true")
        let inspector = ProcessTableDescendantInspector(psExecutableURL: ps)

        let result = inspector.descendantArgv(of: [100])

        #expect(result[100] == nil)
        #expect(result.isEmpty)
    }

    @Test func emptyRequestedPidsShortCircuitsWithoutSpawning() throws {
        // A script that would fail loudly if ever invoked — proves the empty-pids guard skips
        // the spawn entirely rather than merely tolerating a no-op snapshot.
        let ps = try makeFakePS(body: "exit 1")
        let inspector = ProcessTableDescendantInspector(psExecutableURL: ps)

        let result = inspector.descendantArgv(of: [])

        #expect(result.isEmpty)
    }
}
