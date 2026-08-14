/// The coding agent a Tile represents, and the badge glyph shown for it (feature spec §
/// Solution). Codex has no title-pattern signal — its detection depends on the
/// descendant-process fallback (SPEC §2 ladder step 2, TASK-004) — so it has no case here
/// until that task lands.
public enum AgentType: Sendable, Equatable {
    case pi
    case claudeCode

    public var badge: String {
        switch self {
        case .pi: return "π"
        case .claudeCode: return "🟣"
        }
    }
}

private let claudeCodeTitlePrefix = "✳ "
private let piTitlePrefix = "π"

/// One tmux pane classified as running a detected coding agent (SPEC §2), keyed by `pane_id`
/// — the only stable identity (SPEC §2.1).
public struct AgentPane: Identifiable, Equatable, Sendable {
    public let id: String
    public let type: AgentType
    public let label: String
    public let taskText: String?

    /// `label` is built from `windowIndex`/`paneIndex`, never `windowName` — SPEC §3.4: dotted
    /// window names make `window_name` ambiguous. `taskText` is only ever non-nil for
    /// `.claudeCode`: the title's content after the `✳ ` indicator is genuinely a task
    /// description; Pi's title is a project name (already captured in `label` via
    /// `sessionName`), not a task.
    fileprivate init(pane: RawPane, type: AgentType) {
        id = pane.paneId
        self.type = type
        label = "\(pane.sessionName):\(pane.windowIndex).\(pane.paneIndex)"
        switch type {
        case .claudeCode:
            taskText = String(pane.title.dropFirst(claudeCodeTitlePrefix.count))
        case .pi:
            taskText = nil
        }
    }
}

/// Classifies raw pane records into Agent Panes via the title-first detection ladder and
/// `pane_id` dedup across session groups (SPEC §2, §2.1).
///
/// Implements ladder step 1 (title pattern) only — step 2 (descendant-process inspection) is
/// TASK-004. With step 2 absent, SPEC §2's negative signals (hostname/empty/`:path` title,
/// shell/ssh/ngrok command with no title match) and the "matches neither" conservative default
/// collapse onto the same edge: every one of them is a pane with no title match, and every
/// pane with no title match is excluded here — there is no input on which they'd diverge until
/// TASK-004 gives unmatched panes a fallback path. At that point negative-signal panes must
/// skip the descendant walk (they're confidently not agents) while ambiguous panes get it, and
/// this collapse needs to be split back apart.
public struct AgentDetector: Sendable {
    public init() {}

    public func classify(_ panes: [RawPane]) -> [AgentPane] {
        var winners: [String: (pane: RawPane, type: AgentType)] = [:]
        var order: [String] = []
        for pane in panes {
            guard let type = Self.detectType(pane) else { continue }
            if let existing = winners[pane.paneId] {
                // SPEC §2.1: session-group duplicates collapse to one Tile; break ties
                // alphabetically on session name for stability across scans.
                if pane.sessionName < existing.pane.sessionName {
                    winners[pane.paneId] = (pane, type)
                }
            } else {
                winners[pane.paneId] = (pane, type)
                order.append(pane.paneId)
            }
        }
        return order.map { paneId in
            let winner = winners[paneId]!
            return AgentPane(pane: winner.pane, type: winner.type)
        }
    }

    private static func detectType(_ pane: RawPane) -> AgentType? {
        if pane.title.hasPrefix(claudeCodeTitlePrefix) { return .claudeCode }
        if pane.title.hasPrefix(piTitlePrefix) { return .pi }
        return nil
    }
}
