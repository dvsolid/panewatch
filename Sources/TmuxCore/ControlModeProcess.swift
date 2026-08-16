import Foundation

/// New seam (ADR-0005) for a long-lived, line-streaming tmux subprocess — the
/// `ControlModeActivitySource`-facing equivalent of what `TmuxGateway` is for one-shot
/// spawn-and-wait calls. `onLine` fires once per complete line, reassembled regardless of how
/// the underlying reads happen to chunk it; `onTerminate` fires exactly once, on any process
/// exit (natural or via `terminate()`).
public protocol ControlModeProcess: AnyObject, Sendable {
    var onLine: ((String) -> Void)? { get set }
    var onTerminate: (() -> Void)? { get set }

    /// Ends the process deliberately. `onTerminate` still fires (from the same exit-detection
    /// path a natural exit uses) — callers don't need to fire it themselves.
    func terminate()
}

/// Spawns a `ControlModeProcess`. `ControlModeActivitySource` depends on this protocol, never
/// the concrete `ProcessControlModeLauncher`, so its own tests fake `ControlModeProcess`
/// instead of spawning a real `tmux -C attach` (ADR-0005).
public protocol ControlModeProcessLauncher: Sendable {
    func launch(tmuxPath: String, target: String) throws -> any ControlModeProcess
}

/// The live `Process`/`Pipe`-backed adapter, plain Foundation only (ADR-0005 — no
/// SwiftTerm/AppKit in `TmuxCore`). Never invokes tmux bare: the executable is always the
/// resolved `tmuxPath` passed to `launch` (SPEC §6).
public struct ProcessControlModeLauncher: ControlModeProcessLauncher {
    public init() {}

    public func launch(tmuxPath: String, target: String) throws -> any ControlModeProcess {
        let invocation = Self.attachInvocation(tmuxPath: tmuxPath, target: target)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: invocation.executable)
        process.arguments = invocation.arguments

        // Held open, never written to, never closed for the process's full lifetime — SPEC
        // §237: a child whose stdin is connected to something that drains it (e.g. closed
        // immediately, or hooked to a pipe that reaches EOF) exits right away with a spurious
        // `%exit`. Keeping this `Pipe`'s write end open and simply never touching it is what
        // prevents that: tmux's `read()` on its stdin just blocks forever, exactly like an
        // interactive terminal that hasn't typed anything yet.
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let managed = LiveControlModeProcess(process: process, stdinPipe: stdinPipe, stdoutHandle: stdoutPipe.fileHandleForReading)
        try process.run()
        return managed
    }

    /// Extracted so tests can assert the exact argument vector without spawning a real
    /// process — same discipline as `ProcessTmuxGateway.listPanesInvocation` (the acceptance
    /// requirement is that tmux is never invoked bare, which means checking the executable slot
    /// and argument list, not just the path string).
    static func attachInvocation(tmuxPath: String, target: String) -> (executable: String, arguments: [String]) {
        (tmuxPath, ["-C", "attach", "-f", "read-only,ignore-size", "-t", target])
    }
}

/// Reassembles arbitrary `Data` chunks read from a pipe into complete newline-delimited lines,
/// regardless of how the underlying reads happen to split a line — a line straddling two
/// `readabilityHandler` callbacks must still produce exactly one `onLine` call. Kept decoupled
/// from `Process` itself so tests can drive it with a real `Pipe` and hand-written chunk writes
/// instead of depending on how a real subprocess happens to chunk its stdout.
final class ControlModeLineReader: @unchecked Sendable {
    var onLine: ((String) -> Void)?

    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.consume(data)
        }
    }

    /// Stops delivering further lines. Safe to call more than once (e.g. from termination
    /// cleanup after the reader has already been stopped).
    func stop() {
        handle.readabilityHandler = nil
    }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            lines.append(String(decoding: buffer[..<newlineIndex], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        lock.unlock()
        // Fired outside the lock: `onLine` is caller-supplied and may re-enter this object
        // (e.g. calling `terminate()` on the owning `ControlModeProcess`).
        for line in lines {
            onLine?(line)
        }
    }
}

/// The concrete `ControlModeProcess` behind `ProcessControlModeLauncher`. `@unchecked Sendable`
/// like `PollingActivitySource`: `Process.terminationHandler` fires on a system-owned thread
/// while `onLine`/`onTerminate`/`terminate()` may be called from another task, so all mutable
/// stored state (`lineHandler`, `terminateHandler`, `didTerminate`, `pendingLines`) is read and
/// written exclusively under `lock`.
///
/// `init` sets `process.terminationHandler` (and starts the line reader) before the caller
/// starts the process, closing the race TASK-025 built this ordering for — but that only
/// guards this class's own internal delivery path. The *caller* (`ControlModeActivitySource`)
/// still assigns `onLine`/`onTerminate` after getting this instance back from `launch`, which
/// reopens the same shape of race one level up: the process can legitimately terminate (or emit
/// lines) before those setters ever run. `onLine`/`onTerminate` below close that window by
/// buffering (lines) or latching (termination) whatever happened before a handler was set, and
/// replaying it synchronously the moment the setter assigns a non-nil handler — so a caller that
/// assigns the setter late still sees every line and exactly one termination, in order, instead
/// of silently losing whatever happened first.
final class LiveControlModeProcess: ControlModeProcess, @unchecked Sendable {
    private let process: Process
    private let stdinPipe: Pipe // held alive, never written to, never closed — see `launch`.
    private let lineReader: ControlModeLineReader
    private let lock = NSLock()
    private var lineHandler: ((String) -> Void)?
    private var terminateHandler: (() -> Void)?
    private var didTerminate = false
    /// Lines that arrived while `lineHandler` was nil, held in order until `onLine` is next
    /// assigned a non-nil handler, at which point they're replayed and the buffer is cleared.
    private var pendingLines: [String] = []

    var onLine: ((String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return lineHandler }
        set {
            lock.lock()
            lineHandler = newValue
            let buffered = pendingLines
            pendingLines.removeAll()
            lock.unlock()
            guard let newValue else { return }
            for line in buffered {
                newValue(line)
            }
        }
    }

    var onTerminate: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return terminateHandler }
        set {
            lock.lock()
            terminateHandler = newValue
            let alreadyTerminated = didTerminate
            lock.unlock()
            if alreadyTerminated {
                newValue?()
            }
        }
    }

    init(process: Process, stdinPipe: Pipe, stdoutHandle: FileHandle) {
        self.process = process
        self.stdinPipe = stdinPipe
        self.lineReader = ControlModeLineReader(handle: stdoutHandle)

        lineReader.onLine = { [weak self] line in
            self?.deliverLine(line)
        }

        // Set before the caller starts the process (`launch` calls `process.run()` right after
        // constructing this instance) so a process that exits immediately can't race past this
        // assignment and be missed.
        process.terminationHandler = { [weak self] _ in
            self?.fireTerminate()
        }
    }

    private func deliverLine(_ line: String) {
        lock.lock()
        if let handler = lineHandler {
            lock.unlock()
            handler(line)
        } else {
            pendingLines.append(line)
            lock.unlock()
        }
    }

    private func fireTerminate() {
        lock.lock()
        guard !didTerminate else { lock.unlock(); return }
        didTerminate = true
        let handler = terminateHandler
        lock.unlock()

        lineReader.stop()
        handler?()
    }

    func terminate() {
        process.terminate()
    }

    /// Test-only: true once termination has latched internally, independent of whether
    /// `onTerminate` has been assigned — lets tests poll for the pre-handler-assignment race
    /// window instead of sleeping a fixed duration.
    var hasTerminatedForTesting: Bool {
        lock.lock(); defer { lock.unlock() }
        return didTerminate
    }

    /// Test-only: true once at least one line has arrived and is buffered awaiting `onLine`,
    /// independent of whether a handler has been assigned.
    var hasPendingLineForTesting: Bool {
        lock.lock(); defer { lock.unlock() }
        return !pendingLines.isEmpty
    }
}
