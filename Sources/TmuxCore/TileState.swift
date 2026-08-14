/// What `StatusBarShell` renders as one Tile. For this slice (TASK-002) that's just identity
/// and a raw label — no agent-type badge, no color state (those land in TASK-003/TASK-005).
public struct TileState: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String

    /// `label` is built from `windowIndex`/`paneIndex`, never `windowName` — SPEC §3.4:
    /// dotted window names make `window_name` ambiguous, so the raw identifier is always
    /// `session:window.pane` from indices.
    public init(pane: RawPane) {
        id = pane.paneId
        label = "\(pane.sessionName):\(pane.windowIndex).\(pane.paneIndex)"
    }
}
