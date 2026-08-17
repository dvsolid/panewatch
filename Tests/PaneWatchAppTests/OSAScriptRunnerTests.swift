import Foundation
import Testing
@testable import TmuxCore
@testable import PaneWatchApp

/// Exercises `OSAScriptRunner` — the concrete `AppleScriptRunner` adapter — against a fake
/// `osascript`-shaped executable, the same pattern `ProcessTmuxGateway.tmuxPath`/
/// `ProcessTableDescendantInspector.psExecutableURL` use (CLAUDE.md: "shell out through an
/// injectable command runner so the real binary can be faked").
///
/// `SwitchActionPlanner`'s per-app scripts (iTerm2/Terminal.app's window/tab search loops) are
/// multi-line, so the real `osascript` invocation feeds `script` on stdin rather than via `-e`
/// (which only accepts one line of source per flag) — the fake scripts here capture stdin to a
/// file so tests can assert the runner actually fed the script through, not just that it ran
/// *some* command and returned canned stdout.
@Suite struct OSAScriptRunnerTests {
    private func makeFakeOsascript(body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-osascript-\(UUID().uuidString)")
        let script = "#!/bin/sh\n\(body)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func runFeedsScriptOnStdinAndReturnsStdout() throws {
        let capturedInput = FileManager.default.temporaryDirectory
            .appendingPathComponent("captured-stdin-\(UUID().uuidString)")
        let osascript = try makeFakeOsascript(body: """
        cat > \(capturedInput.path)
        echo 'fixed output'
        """)
        let runner = OSAScriptRunner(osascriptExecutableURL: osascript)
        let source = "tell application \"Ghostty\"\n    activate\nend tell"

        let output = try runner.run(script: source)

        #expect(output == "fixed output\n")
        #expect(try String(contentsOf: capturedInput, encoding: .utf8) == source)
    }

    /// Mirrors `ProcessTableDescendantInspector.SnapshotFailed`'s pattern: a script that runs but
    /// fails partway through (a real AppleScript compile/runtime error, e.g. a terminal app not
    /// having a `tty`-addressable window search) can still leave parsable-but-wrong output on
    /// stdout. Only inspecting `terminationStatus` catches this — a bare `try process.run()`
    /// never throws for it, since the process launched and ran just fine.
    @Test func runThrowsWhenOsascriptExitsNonZero() throws {
        let osascript = try makeFakeOsascript(body: """
        cat > /dev/null
        echo 'syntax error: Expected end of line but found identifier.' >&2
        exit 1
        """)
        let runner = OSAScriptRunner(osascriptExecutableURL: osascript)

        #expect(throws: (any Error).self) {
            try runner.run(script: "this is not valid applescript")
        }
    }

    /// The thrown error must carry `osascript`'s own stderr text — the only diagnostic available
    /// for a failed Switch focus attempt — not silently discard it the way inheriting or nulling
    /// stderr would (HEAD commit "Stop leaking tmux stderr and swallowing failed commands" fixed
    /// exactly this class of bug for `ProcessTmuxGateway`).
    @Test func thrownErrorCarriesStderrText() throws {
        let osascript = try makeFakeOsascript(body: """
        cat > /dev/null
        echo 'syntax error: Expected end of line but found identifier.' >&2
        exit 1
        """)
        let runner = OSAScriptRunner(osascriptExecutableURL: osascript)

        #expect {
            try runner.run(script: "this is not valid applescript")
        } throws: { error in
            guard let failure = error as? OSAScriptRunner.ScriptFailed else { return false }
            return failure.terminationStatus == 1
                && failure.stderr == "syntax error: Expected end of line but found identifier.\n"
        }
    }
}
