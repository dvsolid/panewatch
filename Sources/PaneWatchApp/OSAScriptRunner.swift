import Foundation
import TmuxCore

/// The live `AppleScriptRunner`: shells out to `/usr/bin/osascript`. Adapter lives here, not in
/// TmuxCore, per ADR-002 and the feature spec's Adapters-at-seam note — `SwitchActionPlanner`
/// itself never runs real AppleScript, only builds the source string.
public struct OSAScriptRunner: AppleScriptRunner {
    private let osascriptExecutableURL: URL

    public init() {
        self.init(osascriptExecutableURL: URL(fileURLWithPath: "/usr/bin/osascript"))
    }

    /// Test seam: point at a fake `osascript`-shaped executable instead of the real binary —
    /// same pattern as `ProcessTmuxGateway.tmuxPath`/`ProcessTableDescendantInspector.psExecutableURL`.
    init(osascriptExecutableURL: URL) {
        self.osascriptExecutableURL = osascriptExecutableURL
    }

    /// Thrown on a non-zero `osascript` exit rather than trusting whatever landed on stdout —
    /// the same discipline `ProcessTableDescendantInspector.SnapshotFailed` uses for `ps`.
    /// Carries `stderr` (osascript's own compile/runtime error text) rather than discarding it —
    /// the only diagnostic available for a failed Switch focus attempt.
    public struct ScriptFailed: Error {
        public let terminationStatus: Int32
        public let stderr: String
    }

    /// Feeds `script` on stdin rather than via `-e` — `SwitchActionPlanner`'s per-app scripts
    /// (iTerm2/Terminal.app's window/tab search loops) are multi-line, and `-e` only accepts one
    /// line of source per flag; `osascript` with no file argument reads its script from stdin.
    public func run(script: String) throws -> String {
        let process = Process()
        process.executableURL = osascriptExecutableURL
        process.arguments = []

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        stdin.fileHandleForWriting.write(Data(script.utf8))
        try stdin.fileHandleForWriting.close()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ScriptFailed(
                terminationStatus: process.terminationStatus,
                stderr: String(data: errorData, encoding: .utf8) ?? ""
            )
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
