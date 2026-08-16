import Foundation
import Testing
@testable import TmuxCore

/// `ProcessControlModeLauncher`/`LiveControlModeProcess` — the new streaming-subprocess seam
/// (ADR-0005). Two kinds of test here, mirroring `TmuxGatewayTests`' fake-executable pattern
/// (CLAUDE.md: "shell out through an injectable command runner so the real binary can be
/// faked; skip explicitly when tmux is absent"):
///
/// - Most tests point the launcher at a tiny fake `tmux`-shaped shell script (like
///   `TmuxGatewayTests.makeFakeTmux`), so line-streaming/stdin/termination behavior is exercised
///   through the real `Process`/`Pipe` plumbing without depending on a real tmux server.
/// - `livePipesRealControlModeOutputFromTmux` spawns a real tmux session and skips (via
///   `.enabled(if:)`) when no tmux binary is present at `TmuxCore.defaultTmuxPath`.
@Suite struct ControlModeProcessTests {
    private func makeFakeTmux(body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-tmux-control-\(UUID().uuidString)")
        let script = "#!/bin/sh\n\(body)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Waits until `condition()` returns true or `timeout` elapses, polling instead of sleeping
    /// a fixed duration — keeps passing runs fast and failing runs bounded (CLAUDE.md: "Always
    /// pass a timeout... abort hanging tests immediately").
    private func waitUntil(timeout: TimeInterval = 2, _ condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    // MARK: - Acceptance item 1: never invokes tmux bare

    /// Asserts the actual argument vector `ProcessControlModeLauncher` builds (executable slot
    /// vs. arguments), not just that the path string looks absolute — the same discipline
    /// `PaneDiscoveryTests.processGatewayNeverInvokesBareTmux` uses for `ProcessTmuxGateway`.
    @Test func launcherNeverInvokesTmuxBare() {
        let invocation = ProcessControlModeLauncher.attachInvocation(tmuxPath: "/opt/homebrew/bin/tmux", target: "agents:1")

        #expect(invocation.executable == "/opt/homebrew/bin/tmux")
        #expect(invocation.executable.hasPrefix("/"))
        #expect(invocation.arguments == ["-C", "attach", "-f", "read-only,ignore-size", "-t", "agents:1"])
    }

    // MARK: - Acceptance item 2: line reassembly across chunked reads

    /// Fake-pipe harness (no process at all): writes a single line's bytes to a real `Pipe` in
    /// two separate writes straddling the newline, with a deterministic checkpoint in between —
    /// after the first (newline-less) write, no line must have fired yet (proving the reader
    /// buffers a partial line rather than treating each raw read as a complete one); only after
    /// the remainder arrives does exactly one, correctly reassembled line fire. This is the exact
    /// failure mode a naive "treat each `availableData` read as one line" reader would get wrong
    /// — it would fire prematurely on the first write, mid-word.
    @Test func lineReaderReassemblesLineSplitAcrossMultipleReads() {
        let pipe = Pipe()
        let reader = ControlModeLineReader(handle: pipe.fileHandleForReading)
        let lock = NSLock()
        var received: [String] = []
        reader.onLine = { line in
            lock.lock()
            received.append(line)
            lock.unlock()
        }

        pipe.fileHandleForWriting.write("%output %51 hello ".data(using: .utf8)!)

        // Deterministic checkpoint: bounded wait for *absence* of a premature line. A reader
        // that (wrongly) emits on every raw chunk would flip this well inside the window.
        let firedPrematurely = waitUntil(timeout: 0.3) {
            lock.lock()
            defer { lock.unlock() }
            return !received.isEmpty
        }
        #expect(!firedPrematurely)

        pipe.fileHandleForWriting.write("world\n".data(using: .utf8)!)

        let sawLine = waitUntil {
            lock.lock()
            defer { lock.unlock() }
            return received.count == 1
        }
        reader.stop()

        #expect(sawLine)
        lock.lock()
        #expect(received == ["%output %51 hello world"])
        lock.unlock()
    }

    // MARK: - Acceptance item 3: stdin held open

    /// A script that blocks on `read` only returns (and exits) once its stdin reaches EOF or
    /// receives data. If the launcher's stdin pipe were closed or drained instead of held open,
    /// this script would exit almost immediately, firing `onTerminate` well inside the wait
    /// window below. Holding stdin open correctly means the script — and `onTerminate` — never
    /// fires within that window.
    @Test func stdinIsHeldOpenNeverClosedOrDrained() throws {
        let tmux = try makeFakeTmux(body: "read line\necho \"got: $line\"")
        let launcher = ProcessControlModeLauncher()
        let process = try launcher.launch(tmuxPath: tmux.path, target: "agents:1")
        let lock = NSLock()
        var terminated = false
        process.onTerminate = {
            lock.lock()
            terminated = true
            lock.unlock()
        }

        // Bounded, deliberately-failing-fast wait: if stdin were closed/drained, the fake
        // script's `read` returns immediately and this would flip `terminated` well before the
        // deadline.
        let neverTerminated = !waitUntil(timeout: 0.5) {
            lock.lock()
            defer { lock.unlock() }
            return terminated
        }
        process.terminate()

        #expect(neverTerminated)
    }

    // MARK: - Acceptance item 4: onTerminate fires exactly once

    @Test func onTerminateFiresExactlyOnceOnNaturalExit() throws {
        let tmux = try makeFakeTmux(body: "exit 0")
        let launcher = ProcessControlModeLauncher()
        let process = try launcher.launch(tmuxPath: tmux.path, target: "agents:1")
        let lock = NSLock()
        var terminateCount = 0
        process.onTerminate = {
            lock.lock()
            terminateCount += 1
            lock.unlock()
        }

        let firedOnce = waitUntil {
            lock.lock()
            defer { lock.unlock() }
            return terminateCount == 1
        }
        // Give a duplicate-fire bug a chance to show up before asserting the final count.
        _ = waitUntil(timeout: 0.2) { false }

        #expect(firedOnce)
        lock.lock()
        #expect(terminateCount == 1)
        lock.unlock()
    }

    /// Calling `terminate()` twice on an already-exited process must not double-fire
    /// `onTerminate` — the "by any means" half of this acceptance item.
    @Test func onTerminateDoesNotDoubleFireWhenTerminateCalledRepeatedly() throws {
        let tmux = try makeFakeTmux(body: "while true; do sleep 60; done")
        let launcher = ProcessControlModeLauncher()
        let process = try launcher.launch(tmuxPath: tmux.path, target: "agents:1")
        let lock = NSLock()
        var terminateCount = 0
        process.onTerminate = {
            lock.lock()
            terminateCount += 1
            lock.unlock()
        }

        process.terminate()
        let firedOnce = waitUntil {
            lock.lock()
            defer { lock.unlock() }
            return terminateCount == 1
        }
        process.terminate() // second call after exit — must be a no-op for onTerminate
        _ = waitUntil(timeout: 0.2) { false }

        #expect(firedOnce)
        lock.lock()
        #expect(terminateCount == 1)
        lock.unlock()
    }

    // MARK: - Acceptance item 5: terminate() ends a running process

    @Test func terminateEndsARunningProcess() throws {
        let tmux = try makeFakeTmux(body: "while true; do sleep 60; done")
        let launcher = ProcessControlModeLauncher()
        let process = try launcher.launch(tmuxPath: tmux.path, target: "agents:1")
        let lock = NSLock()
        var terminated = false
        process.onTerminate = {
            lock.lock()
            terminated = true
            lock.unlock()
        }

        process.terminate()
        let didTerminate = waitUntil {
            lock.lock()
            defer { lock.unlock() }
            return terminated
        }

        #expect(didTerminate)
    }

    // MARK: - Acceptance item 6: live end-to-end against real tmux

    /// Skips (rather than fails) when no tmux binary is present at `TmuxCore.defaultTmuxPath` —
    /// same convention `TmuxGatewayTests` establishes for fake-executable tests, extended here
    /// to an actual live-server dependency per this task's Test seam and the feature spec's
    /// "Tests that do need a live tmux server skip explicitly when tmux is absent" decision.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: TmuxCore.defaultTmuxPath)))
    func livePipesRealControlModeOutputFromTmux() throws {
        let tmuxPath = TmuxCore.defaultTmuxPath
        let gateway = ProcessTmuxGateway(tmuxPath: tmuxPath)
        let sessionName = "tmuxer-mac-test-\(UUID().uuidString.prefix(8))"
        _ = try gateway.run(["new-session", "-d", "-s", sessionName, "-x", "80", "-y", "24"])
        defer { _ = try? gateway.run(["kill-session", "-t", sessionName]) }

        let launcher = ProcessControlModeLauncher()
        let process = try launcher.launch(tmuxPath: tmuxPath, target: sessionName)
        defer { process.terminate() }

        let lock = NSLock()
        var lines: [String] = []
        process.onLine = { line in
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        // Give the control client a moment to attach before sending keys, then produce real
        // output in the session — this is what should surface as a real `%output` line.
        _ = waitUntil(timeout: 1) { false }
        _ = try gateway.run(["send-keys", "-t", sessionName, "echo hello-control-mode", "Enter"])

        let sawOutputLine = waitUntil(timeout: 5) {
            lock.lock()
            defer { lock.unlock() }
            return lines.contains { $0.hasPrefix("%output ") }
        }

        #expect(sawOutputLine)
    }
}
