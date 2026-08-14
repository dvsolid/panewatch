/// What `StatusBarShell` renders as one Tile: an already-classified Agent Pane (TASK-003) —
/// identity, label, agent-type badge, (for Claude Code) task text, and its live Activity Phase
/// (TASK-005). `phase` carries color via `ActivityPhase.color` — `TileState` itself stays a
/// plain data holder; `StatusBarEngine` is what derives `phase` for a given pane and instant.
public struct TileState: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let badge: String
    public let taskText: String?
    public let phase: ActivityPhase

    public init(pane: AgentPane, phase: ActivityPhase) {
        id = pane.id
        label = pane.label
        badge = pane.type.badge
        taskText = pane.taskText
        self.phase = phase
    }
}
