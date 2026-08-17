import Foundation

/// The coding agent a Tile represents, and the badge glyph shown for it (feature spec §
/// Solution). Codex has no title-pattern signal — tmux never observed setting a
/// distinguishing `pane_title` for it — so its detection depends entirely on the
/// descendant-process fallback (SPEC §2 ladder step 2). Confirmed against a live Codex
/// process: its argv basename is exactly `codex` (bare, no arguments), the same
/// bare-executable-name shape already relied on for Pi/Claude Code, so it's added as
/// ladder step 2's third marker.
public enum AgentType: Sendable, Equatable {
    case pi
    case claudeCode
    case codex

    public var badge: BadgeGlyph {
        switch self {
        case .pi: return .text("π")
        case .claudeCode: return .symbol(name: "sparkle")
        case .codex: return .symbol(name: "chevron.left.forwardslash.chevron.right")
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
    /// Carried through from `RawPane.windowActivityAt` — see its doc comment.
    public let windowActivityAt: Date
    /// Carried through from `RawPane.sessionName` — the same value `label` embeds, kept as its
    /// own field so callers that need just the session (e.g. `StatusBarEngine.reconcile()`
    /// building the `ActivitySource.setWatchedPanes` pane-id -> session-name map, ADR-0004)
    /// don't have to parse it back out of `label`.
    public let sessionName: String
    /// Carried through from `RawPane.windowIndex`, same reasoning as `sessionName`:
    /// `StatusBarEngine.reconcile()` needs it, alongside `sessionName`, to group panes by tmux
    /// window when deciding whether `windowActivityAt` can be trusted as *this* pane's own last
    /// output — see `windowActivityAt`'s doc comment on `RawPane` for why that's window-scoped,
    /// not pane-scoped.
    public let windowIndex: Int

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
        windowActivityAt = pane.windowActivityAt
        sessionName = pane.sessionName
        windowIndex = pane.windowIndex
        if type == .claudeCode && matchedTitle {
            taskText = String(pane.title.dropFirst(claudeCodeTitlePrefix.count))
        } else {
            taskText = nil
        }
    }
}

/// Caches ladder step 3's fallback-walk results per `pane_id` — never title-match corroboration
/// (TASK-013), which is deliberately re-walked every pass — class-backed (a reference type) so
/// the cache survives across repeated `AgentDetector.classify()` calls on the same detector
/// instance despite `AgentDetector`'s value semantics — SPEC §2: "run it once per newly-seen
/// pane_id and cache the result for the pane's lifetime," which spans many discovery passes
/// (TASK-006), not one. Lock-protected because `AgentDetector` is `Sendable` and must stay safe
/// if discovery and probe timers ever call it from different tasks.
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
/// 1. Title pattern (`π`/`✳ ` prefix) — comes free with the `list-panes` format string, but not
///    final: corroborated against a live agent descendant every pass (TASK-013), since tmux's
///    `pane_title` is sticky and outlives the process that set it. Uncached, unlike step 3 below
///    — see `detectType`'s `.matched` case.
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
        // Exclude a Preview Client's own synthetic grouped session (`PreviewClientInvocation
        // .groupSessionPrefix`) before anything else — whole-branch review finding: while a
        // hover popup is open, its group session shares the hovered pane's pane_id with the
        // pane's real source session, so `list-panes -a` reports the same pane_id twice. Left
        // in, the group's row can win the dedup tie-break below (it sorts after most real
        // session names) and relabel the Tile with `panewatch-preview-<N>:...` until the popup
        // closes and the next discovery pass corrects it (~30s later). `session_grouped`/
        // `session_group` can't discriminate here — tmux reports both the group and its
        // source session as grouped once linked — so the deterministic naming convention is
        // the only reliable signal.
        let panes = panes.filter { !$0.sessionName.hasPrefix(PreviewClientInvocation.groupSessionPrefix) }

        // One descendant-process walk per discovery pass covers both ladder step 1's
        // corroboration and step 2's fallback: `descendantArgv(of:)` snapshots the entire
        // process table regardless of how many pids it's asked about, so gather every pid that
        // needs a walk this pass first and walk them together (TASK-004's measured cost: ~50ms
        // warm per `ps -A` spawn, so N spawns per pass collapses to 1). Title matches are added
        // unconditionally, every pass, uncached — see `detectType`'s `.matched` case for why.
        // Fallback-ladder pids are added only when uncached, since that resolution is memoized
        // for the pane's lifetime.
        var pidsNeedingWalk: Set<Int32> = []
        for pane in panes {
            switch titleSignal(pane) {
            case .matched:
                pidsNeedingWalk.insert(pane.pid)
            case .needsDescendantWalk:
                let (walked, _) = cache.lookup(pane.paneId)
                if !walked { pidsNeedingWalk.insert(pane.pid) }
            case .excluded:
                continue
            }
        }
        let batchArgv = pidsNeedingWalk.isEmpty ? [:] : descendantInspector.descendantArgv(of: pidsNeedingWalk)

        var winners: [String: Candidate] = [:]
        var order: [String] = []
        for pane in panes {
            guard let (type, matchedTitle) = detectType(pane, batchArgv: batchArgv) else { continue }
            if let existing = winners[pane.paneId] {
                // SPEC §2.1: session-group duplicates collapse to one Tile; break ties
                // alphabetically on session name for stability across scans.
                if pane.sessionName < existing.pane.sessionName {
                    winners[pane.paneId] = Candidate(pane: pane, type: type, matchedTitle: matchedTitle)
                }
            } else {
                winners[pane.paneId] = Candidate(pane: pane, type: type, matchedTitle: matchedTitle)
                order.append(pane.paneId)
            }
        }
        return order.map { paneId in
            let winner = winners[paneId]!
            return AgentPane(pane: winner.pane, type: winner.type, matchedTitle: winner.matchedTitle)
        }
    }

    private struct Candidate {
        let pane: RawPane
        let type: AgentType
        let matchedTitle: Bool
    }

    private enum TitleSignal {
        case matched(type: AgentType)
        case excluded
        case needsDescendantWalk
    }

    private func titleSignal(_ pane: RawPane) -> TitleSignal {
        if pane.title.hasPrefix(claudeCodeTitlePrefix) { return .matched(type: .claudeCode) }
        if pane.title.hasPrefix(piTitlePrefix) { return .matched(type: .pi) }
        if pane.title == hostname || pane.title.hasPrefix(":") { return .excluded }
        return .needsDescendantWalk
    }

    private func detectType(_ pane: RawPane, batchArgv: [Int32: [String]]) -> (type: AgentType, matchedTitle: Bool)? {
        switch titleSignal(pane) {
        case .matched(let type):
            // A title match is corroborated against a live descendant, not treated as final —
            // tmux's `pane_title` is sticky (this task's motivating bug: a title set by an agent
            // that has since exited never clears). Uncached, unlike ladder step 2's fallback
            // resolution: "does this shell wrap an agent" is stable for the pane's life, but "is
            // that agent still alive" is not, so this must be re-checked every pass.
            //
            // A pid absent from `batchArgv` means the walk didn't run this pass (e.g. the `ps`
            // snapshot failed) — fail open and keep the title-based classification rather than
            // demoting on a snapshot failure.
            guard let argv = batchArgv[pane.pid] else { return (type, true) }
            return Self.matchAgentType(argv: argv) != nil ? (type, true) : nil
        case .excluded:
            return nil
        case .needsDescendantWalk:
            let (walked, cachedType) = cache.lookup(pane.paneId)
            if walked {
                return cachedType.map { ($0, false) }
            }
            // A pid absent from `batchArgv` means the walk didn't run this pass (e.g. the `ps`
            // snapshot failed) — don't cache in that case, so this pane gets retried on the
            // next discovery pass instead of being permanently marked "no agent descendant".
            guard let argv = batchArgv[pane.pid] else { return nil }
            let type = Self.matchAgentType(argv: argv)
            cache.store(type, for: pane.paneId)
            return type.map { ($0, false) }
        }
    }

    /// Executable-basename markers for SPEC §2 ladder step 2, also reused by ladder step 1's
    /// title-match corroboration (TASK-013). Basename equality, not substring
    /// containment: a substring search for `"pi"` would false-positive on `pip`,
    /// `raspi-config`, anything with "pi" inside a longer name — the same class of loose-match
    /// mistake SPEC calls out for the Claude Code version string.
    private static let agentProcessNames: [String: AgentType] = [
        "claude": .claudeCode,
        "pi": .pi,
        "codex": .codex
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
