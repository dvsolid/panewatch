/// What `StatusBarShell` renders as one Tile: an already-classified Agent Pane (TASK-003) —
/// identity, label, agent-type badge, and (for Claude Code) task text. No color state yet
/// (TASK-005).
public struct TileState: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let badge: String
    public let taskText: String?

    public init(pane: AgentPane) {
        id = pane.id
        label = pane.label
        badge = pane.type.badge
        taskText = pane.taskText
    }
}
