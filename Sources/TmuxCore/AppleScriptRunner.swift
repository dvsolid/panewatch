/// Executes an AppleScript source string, returning its output or throwing. Isolates the one
/// place anything actually shells out to `osascript`, so `SwitchActionPlanner`'s output stays
/// testable without ever running real AppleScript against real apps — mirrors `TmuxGateway`'s
/// split between protocol and concrete process-shelling adapter. Feature spec § Architecture
/// (`AppleScriptRunner`), ADR-002.
public protocol AppleScriptRunner: Sendable {
    /// Runs `script` as AppleScript source and returns its stdout. Throws rather than returning
    /// empty/partial output silently on a non-zero exit — the same discipline
    /// `ProcessTmuxGateway.run`/`ProcessTableDescendantInspector.snapshotProcessTable` use for
    /// their own subprocess spawns.
    func run(script: String) throws -> String
}
