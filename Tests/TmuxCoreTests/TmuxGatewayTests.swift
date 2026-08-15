import Foundation
import Testing
@testable import TmuxCore

/// Exercises `ProcessTmuxGateway` itself (not `FakeTmuxGateway`, used everywhere else) —
/// specifically `run()`'s failure-signal handling. Before this test file existed, nothing
/// spawned a real subprocess through this type, so a tmux invocation that fails (e.g.
/// `capture-pane` against a pane that closed between the discovery scan and the next probe)
/// could regress silently in two ways: the caller never learns the command failed (empty stdout
/// looks identical to a genuinely empty pane), and tmux's own error text — inherited stderr,
/// never redirected — leaks straight into whatever terminal or log is watching the app's own
/// stderr. This was a real, user-visible bug: `can't find pane: %81` appearing unprompted after
/// closing a pane tmuxer-mac was watching.
///
/// Each test writes a tiny fake `tmux`-shaped shell script to a temp file and points the gateway
/// at it via the `tmuxPath` test seam — the same pattern
/// `ProcessTableDescendantInspector.psExecutableURL` uses (CLAUDE.md: "shell out through an
/// injectable command runner so the real binary can be faked").
@Suite struct TmuxGatewayTests {
    private func makeFakeTmux(body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-tmux-\(UUID().uuidString)")
        let script = "#!/bin/sh\n\(body)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func capturePaneReturnsStdoutOnSuccess() throws {
        let tmux = try makeFakeTmux(body: "echo 'agent output'")
        let gateway = ProcessTmuxGateway(tmuxPath: tmux.path)

        let output = try gateway.capturePane("%51")

        #expect(output == "agent output\n")
    }

    /// The bug's core: a pane that closed between the discovery scan and the next probe makes
    /// `capture-pane` exit non-zero. Only inspecting `terminationStatus` catches this — a bare
    /// `try process.run()` never throws for it, since the process launched and ran just fine.
    @Test func capturePaneThrowsWhenTmuxExitsNonZero() throws {
        let tmux = try makeFakeTmux(body: """
        echo "can't find pane: %81" >&2
        exit 1
        """)
        let gateway = ProcessTmuxGateway(tmuxPath: tmux.path)

        #expect(throws: (any Error).self) {
            try gateway.capturePane("%81")
        }
    }

    @Test func listPanesThrowsWhenTmuxExitsNonZero() throws {
        let tmux = try makeFakeTmux(body: """
        echo 'no server running on /tmp/tmux-501/default' >&2
        exit 1
        """)
        let gateway = ProcessTmuxGateway(tmuxPath: tmux.path)

        #expect(throws: (any Error).self) {
            try gateway.listPanes()
        }
    }
}
