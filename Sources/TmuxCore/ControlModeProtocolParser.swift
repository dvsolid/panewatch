import Foundation

/// The classification of one complete tmux control-mode line (SPEC §3.2).
public enum ControlModeEvent: Equatable, Sendable {
    /// `%output <pane-id> <data...>` — only the pane id, never the payload (SPEC §230).
    case output(paneId: String)
    /// `%exit` — the control client's session was killed.
    case exit
    /// Every other line, including `%begin`/`%end`/`%session-changed` and any unrecognized
    /// future `%`-prefixed notification. Never treated as an error — forward compatibility
    /// with tmux versions that add new notification types (SPEC §238).
    case other
}

/// Pure classification of one tmux control-mode wire line, hiding the wire format (SPEC
/// §3.2) behind a function testable against a captured transcript with no process involved.
/// No process, no I/O: pure string-in, enum-out. Timestamps are deliberately not this
/// module's concern — the caller reads its own clock at receipt time.
public enum ControlModeProtocolParser {
    public static func parse(_ line: String) -> ControlModeEvent {
        if line == "%exit" {
            return .exit
        }
        if line.hasPrefix("%output ") {
            let rest = line.dropFirst("%output ".count)
            let paneId = rest.prefix { $0 != " " }
            return .output(paneId: String(paneId))
        }
        return .other
    }
}
