import Foundation

/// The coding agent a Tile represents, and the badge glyph shown for it (feature spec §
/// Solution). Codex has no title-pattern signal — its detection depends entirely on the
/// descendant-process fallback (SPEC §2 ladder step 2) — but SPEC gives no observed Codex argv
/// pattern to match on (unlike Pi/Claude Code, which SPEC's Technical Findings captured from a
/// live server), so it still has no case here: adding one now would be an invented marker with
/// no evidence behind it, the exact failure mode SPEC warns against for the Claude Code
/// version-string signal. Add it when a real Codex argv pattern is known.
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
    /// `.claudeCode` panes classified *via title* — the title's content after the `✳ `
    /// indicator is genuinely a task description. A `.claudeCode` pane classified via the
    /// descendant fallback (TASK-004) has no `✳ `-prefixed title to strip (that's the whole
    /// reason it needed the fallback), so `taskText` stays nil there too; slicing
    /// `dropFirst(2)` off an arbitrary title would produce garbage, not a task description.
    fileprivate init(pane: RawPane, type: AgentType, matchedTitle: Bool) {
        id = pane.paneId
        self.type = type
        label = "\(pane.sessionName):\(pane.windowIndex).\(pane.paneIndex)"
        if type == .claudeCode && matchedTitle {
            taskText = String(pane.title.dropFirst(claudeCodeTitlePrefix.count))
        } else {
            taskText = nil
        }
    }
}

/// Caches descendant-walk results per `pane_id`, class-backed (a reference type) so the cache
/// survives across repeated `AgentDetector.classify()` calls on the same detector instance
/// despite `AgentDetector`'s value semantics — SPEC §2: "run it once per newly-seen pane_id and
/// cache the result for the pane's lifetime," which spans many discovery passes (TASK-006), not
/// one. Lock-protected because `AgentDetector` is `Sendable` and must stay safe if discovery
/// and probe timers ever call it from different tasks.
///
/// `walked`/`resolvedType` are two parallel collections rather than one `[String: AgentType?]`
/// (double-optional) so "walked, found nothing" and "not walked yet" read as distinct states
/// without a nested-Optional squint.
private final class DescendantWalkCache: @unchecked Sendable {
    private var walked: Set<String> = []
    private var resolvedType: [String: AgentType] = [:]
    private let lock = NSLock()

    /// `nil` means "not walked yet — go walk it." `.some(nil)` (as `AgentType??`... avoided
    /// above) isn't representable here on purpose: callers get `(walked: Bool, type:
    /// AgentType?)` instead.
    func lookup(_ paneId: String) -> (walked: Bool, type: AgentType?) {
        lock.lock()
        defer { lock.unlock() }
        return (walked.contains(paneId), resolvedType[paneId])
    }

    func store(_ type: AgentType?, for paneId: String) {
        lock.lock()
        defer { lock.unlock() }
        walked.insert(paneId)
        resolvedType[paneId] = type
    }
}

/// Classifies raw pane records into Agent Panes via the title-first detection ladder,
/// descendant-process fallback, and `pane_id` dedup across session groups (SPEC §2, §2.1).
///
/// **Ladder:**
/// 1. Title pattern (`π`/`✳ ` prefix) — free, comes with the `list-panes` format string.
/// 2. Negative signal: `pane_title` equal to `hostname` or `:<path>`-prefixed — tmux's default
///    for a pane nothing has branded (SPEC §2). Excluded without a descendant walk.
/// 3. Descendant-process fallback (SPEC §2 ladder step 2), cached per `pane_id` — every
///    remaining pane, including an empty-titled or shell/ssh/ngrok-commanded one, gets this:
///    SPEC's own negative-signal wording for the shell/ssh/ngrok case is conditioned on "and no
///    agent descendant," and the Slice's motivating scenario is precisely an agent hiding
///    behind an *unlabeled* (empty-title) shell — so those panes cannot be excluded before the
///    walk runs, only after it comes back empty.
public struct AgentDetector: Sendable {
    private let hostname: String
    private let descendantInspector: any DescendantProcessInspector
    private let cache = DescendantWalkCache()

    public init(
        hostname: String = ProcessInfo.processInfo.hostName,
        descendantInspector: any DescendantProcessInspector = ProcessTableDescendantInspector()
    ) {
        self.hostname = hostname
        self.descendantInspector = descendantInspector
    }

    public func classify(_ panes: [RawPane]) -> [AgentPane] {
        var winners: [String: (pane: RawPane, type: AgentType, matchedTitle: Bool)] = [:]
        var order: [String] = []
        for pane in panes {
            guard let (type, matchedTitle) = detectType(pane) else { continue }
            if let existing = winners[pane.paneId] {
                // SPEC §2.1: session-group duplicates collapse to one Tile; break ties
                // alphabetically on session name for stability across scans.
                if pane.sessionName < existing.pane.sessionName {
                    winners[pane.paneId] = (pane, type, matchedTitle)
                }
            } else {
                winners[pane.paneId] = (pane, type, matchedTitle)
                order.append(pane.paneId)
            }
        }
        return order.map { paneId in
            let winner = winners[paneId]!
            return AgentPane(pane: winner.pane, type: winner.type, matchedTitle: winner.matchedTitle)
        }
    }

    private func detectType(_ pane: RawPane) -> (type: AgentType, matchedTitle: Bool)? {
        if pane.title.hasPrefix(claudeCodeTitlePrefix) { return (.claudeCode, true) }
        if pane.title.hasPrefix(piTitlePrefix) { return (.pi, true) }
        if pane.title == hostname || pane.title.hasPrefix(":") { return nil }

        let (walked, cachedType) = cache.lookup(pane.paneId)
        if walked {
            return cachedType.map { ($0, false) }
        }
        let argv = descendantInspector.descendantArgv(of: pane.pid)
        let type = Self.matchAgentType(argv: argv)
        cache.store(type, for: pane.paneId)
        return type.map { ($0, false) }
    }

    /// Executable-basename markers for SPEC §2 ladder step 2. Basename equality, not substring
    /// containment: a substring search for `"pi"` would false-positive on `pip`,
    /// `raspi-config`, anything with "pi" inside a longer name — the same class of loose-match
    /// mistake SPEC calls out for the Claude Code version string.
    private static let agentProcessNames: [String: AgentType] = [
        "claude": .claudeCode,
        "pi": .pi,
    ]

    private static func matchAgentType(argv: [String]) -> AgentType? {
        for command in argv {
            let executablePath = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
            let basename = (executablePath as NSString).lastPathComponent.lowercased()
            if let type = agentProcessNames[basename] { return type }
        }
        return nil
    }
}
