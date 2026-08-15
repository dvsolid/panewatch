import Foundation
import Testing
@testable import TmuxCore

/// The hostname baked into the captured fixture's `LMYG2LW3F` rows (SPEC §2's negative
/// signal). Passed explicitly to `AgentDetector` rather than relying on the real
/// `ProcessInfo.processInfo.hostName` — tests must not depend on the machine they run on.
private let fixtureHostname = "LMYG2LW3F"

/// Records every `pid` it's asked about (per batch call) and returns canned argv for it —
/// TASK-004's Test seam: "descendant-process data is injected via a fake (no real process tree
/// walked in tests)." A class (not a struct) so the call log survives across the multiple
/// `classify()` invocations a caching test needs to make against one shared `AgentDetector`.
private final class FakeDescendantProcessInspector: DescendantProcessInspector, @unchecked Sendable {
    private var argvByPID: [Int32: [String]]
    private var callCounts: [Int32: Int] = [:]
    /// Number of times `descendantArgv(of:)` itself was invoked — i.e. how many `ps -A`-
    /// equivalent snapshots this simulates, regardless of how many pids were in each batch.
    private(set) var batchCallCount = 0
    private let lock = NSLock()

    init(argvByPID: [Int32: [String]] = [:]) {
        self.argvByPID = argvByPID
    }

    func descendantArgv(of pids: Set<Int32>) -> [Int32: [String]] {
        lock.lock()
        batchCallCount += 1
        for pid in pids { callCounts[pid, default: 0] += 1 }
        let argvByPID = self.argvByPID
        lock.unlock()
        var result: [Int32: [String]] = [:]
        for pid in pids { result[pid] = argvByPID[pid] ?? [] }
        return result
    }

    func callCount(for pid: Int32) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return callCounts[pid] ?? 0
    }

    /// Mutates canned argv for one pid mid-test — TASK-013's no-memoization acceptance: a pane's
    /// live agent descendant disappearing between two `classify()` passes must change pass 2's
    /// output without touching pass 1's, which a permanently-cached fake couldn't simulate.
    func setArgv(_ argv: [String], for pid: Int32) {
        lock.lock()
        argvByPID[pid] = argv
        lock.unlock()
    }
}

/// Synthetic row appended to `capturedPaneListFixture` for the group-dedup acceptance item.
/// SPEC §2.1: `session_group_size=1` on the reference machine today (the duplication is
/// latent, not currently reproducing) — no captured row exists for two *different* session
/// names sharing a pane. This row puts the fixture's `%51` (Claude Code) under a second
/// session name `t2q-2` in the same group `t2q`, matching SPEC's "design for it now" guidance.
private let groupDuplicatePaneRow = "%51|t2q-2|1|2.1.228|2|2.1.222|✳ Investigate JIRA bug BZS-19252|54430|/dev/ttys051|/Users/dmitryv/Work/Projects/billing/text2quote|1|t2q|0"

/// Synthetic row for acceptance item 6: a pane matching neither a title pattern (not π, not
/// `✳ `) nor a negative signal (title non-empty, not the hostname, not `:path`;
/// `pane_current_command` is `node`, outside the {ngrok, ssh, zsh, bash, fish} set). No such
/// row exists in the captured fixture — every real pane on the reference machine happened to
/// land on one side or the other. Distinct from the hostname-title case (item 4): this checks
/// that an unrecognized-but-plausible-looking title doesn't sneak through as an "unknown"
/// Tile, and that `pane_current_command` never drives a positive ID on its own (SPEC §2).
private let ambiguousPaneRow = "%99|qtc-auto|1|main|4|node|dev-server|9001|/dev/ttys099|/Users/dmitryv/Work/Projects/billing/qtc-ops-automation|0||0"

/// Default descendant inspector for tests that aren't exercising the fallback or TASK-013
/// corroboration directly. Every ladder-step-2-eligible pid (not seeded below) resolves to "no
/// agent descendant" (acceptance item 2's shape). The captured fixture's title-matched panes
/// (`%29`/`%54` pi, `%9`/`%51` claude) are seeded with a live descendant of the *matching* type
/// — this is a live capture, so these agents were genuinely running — so that TASK-013's
/// corroboration doesn't demote them and every test written before TASK-013 keeps passing for
/// the same reason it always did (the title), not because corroboration happens to be
/// type-agnostic. A test exercising corroboration itself configures its own inspector instead.
private func classify(
    _ output: String,
    descendantInspector: any DescendantProcessInspector = FakeDescendantProcessInspector(argvByPID: [
        25236: ["/usr/local/bin/pi"], // %29
        29302: ["/usr/local/bin/pi"], // %54
        8569: ["/usr/local/bin/claude"], // %9
        54430: ["/usr/local/bin/claude"], // %51
    ])
) throws -> [AgentPane] {
    try AgentDetector(hostname: fixtureHostname, descendantInspector: descendantInspector)
        .classify(PaneDiscovery.parse(output))
}

@Suite struct AgentDetectorTests {
    /// Acceptance items 1 + 4: plain shell (`%28`, `%45`), ngrok (`%5`), and hostname-titled
    /// (`%11`, `%5`) panes never produce an `AgentPane`. `%28`/`%45` have empty titles; `%11`
    /// and `%5` both carry the hostname `LMYG2LW3F` as their title — tmux's default when
    /// nothing branded the pane (SPEC §2's negative signal).
    @Test func plainShellSshNgrokAndHostnameTitledPanesAreExcluded() throws {
        let panes = try classify(capturedPaneListFixture)
        let excludedIds: Set<String> = ["%28", "%45", "%11", "%5"]

        let survivors = panes.map(\.id).filter { excludedIds.contains($0) }

        #expect(survivors.isEmpty)
    }

    /// Acceptance item 2: a Pi pane (title starting `π`) appears with the Pi badge, labeled
    /// by session/project name. `%29` is Pi via a `zsh` command (SPEC §2's warning that `cmd`
    /// is not a reliable signal — title is what must drive this).
    @Test func piTitleProducesPiBadgedAgentPane() throws {
        let panes = try classify(capturedPaneListFixture)

        let pi = try #require(panes.first { $0.id == "%29" })
        #expect(pi.type == .pi)
        #expect(pi.type.badge == .text("π"))
        #expect(pi.label == "billing-advisor:1.2")
    }

    /// Acceptance item 3: a Claude Code pane (title starting `✳ `) appears with the Claude
    /// Code badge and its task text shown on the Tile — the text is the title with the `✳ `
    /// indicator stripped, not the raw title.
    @Test func claudeCodeTitleProducesBadgedAgentPaneWithTaskText() throws {
        let panes = try classify(capturedPaneListFixture)

        let claude = try #require(panes.first { $0.id == "%9" })
        #expect(claude.type == .claudeCode)
        #expect(claude.taskText == "task-execution-workflow")
    }

    /// TASK-010 acceptance item 1: Claude Code's badge is the SF Symbol `sparkle`, not the
    /// `🟣` emoji — `BadgeGlyph` keeps this headlessly testable in `TmuxCore` (feature spec §
    /// Architecture) even though the actual SF Symbol image is only ever constructed at the
    /// `TmuxerApp` boundary (`TileCardView`).
    @Test func claudeCodeBadgeIsSparkleSFSymbol() throws {
        #expect(AgentType.claudeCode.badge == .symbol(name: "sparkle"))
    }

    /// TASK-010 acceptance item 2: Pi's badge stays the literal `π` text glyph — visually
    /// unchanged by the `BadgeGlyph` type introduction, unlike Claude Code's.
    @Test func piBadgeIsTextGlyph() throws {
        #expect(AgentType.pi.badge == .text("π"))
    }

    /// Acceptance item 5: two sessions in the same session group (`t2q`/`t2q-2`) that share a
    /// window produce exactly one Tile for the shared pane (`%51`), not two, deduped on
    /// `pane_id` per SPEC §2.1 — never on `session:window.pane`, which would see two distinct
    /// identifiers here and render a duplicate.
    @Test func sharedPaneAcrossGroupedSessionsProducesExactlyOneAgentPane() throws {
        let panes = try classify(capturedPaneListFixture + "\n" + groupDuplicatePaneRow)

        let matches = panes.filter { $0.id == "%51" }

        #expect(matches.count == 1)
    }

    /// The group-dedup winner is deterministic (SPEC §2.1's "break ties alphabetically for
    /// stability") rather than depending on input order: `t2q` sorts before `t2q-2`, so the
    /// surviving row's label is built from `t2q`, not `t2q-2`, regardless of which row the
    /// duplicate `list-panes` output happened to list first.
    @Test func groupDedupTieBreaksAlphabeticallyOnSessionName() throws {
        let panes = try classify(capturedPaneListFixture + "\n" + groupDuplicatePaneRow)

        let survivor = try #require(panes.first { $0.id == "%51" })
        #expect(survivor.label == "t2q:1.2")
    }

    /// Acceptance item 6: a pane whose title matches neither a title pattern nor a hostname
    /// negative signal now reaches the descendant fallback (TASK-004) instead of being
    /// excluded outright — but with no agent descendant configured on the default fake, the
    /// walk comes back empty and the pane is still excluded, not shown as an unknown/ambiguous
    /// Tile.
    @Test func ambiguousPaneMatchingNeitherPatternNorNegativeSignalIsExcluded() throws {
        let panes = try classify(capturedPaneListFixture + "\n" + ambiguousPaneRow)

        #expect(panes.first { $0.id == "%99" } == nil)
    }

    // MARK: - TASK-004: descendant-process fallback classification

    /// Acceptance item 1: a pane with no distinguishing title (`%28` — empty title, `zsh`
    /// command) whose process tree contains a known agent process is classified and shown as a
    /// Tile. This also covers the Test seam's third scenario ("a pane where the title-only
    /// pass from TASK-003 would have made the wrong call without the fallback"): `%28` is
    /// excluded by every other test in this file (they all use the empty-argv default fake);
    /// only injecting an agent descendant for its pid flips the outcome.
    @Test func paneWithAgentProcessInDescendantsIsClassifiedDespiteNoDistinguishingTitle() throws {
        let inspector = FakeDescendantProcessInspector(argvByPID: [8578: ["/usr/local/bin/claude"]])

        let panes = try classify(capturedPaneListFixture, descendantInspector: inspector)

        let tile = try #require(panes.first { $0.id == "%28" })
        #expect(tile.type == .claudeCode)
        // No `✳ `-prefixed title existed to derive this from (AgentPane's `matchedTitle` guard).
        #expect(tile.taskText == nil)
    }

    /// Acceptance item 2: a pane with no distinguishing title and no agent process anywhere in
    /// its descendants remains excluded — no false positive introduced. `%45` (empty title,
    /// `zsh`) gets a non-empty but non-agent descendant list, so exclusion follows from the
    /// walk's content, not merely from a fake that happens to return nothing.
    @Test func paneWithNoAgentProcessInDescendantsRemainsExcluded() throws {
        let inspector = FakeDescendantProcessInspector(argvByPID: [32244: ["/bin/zsh", "/usr/bin/less"]])

        let panes = try classify(capturedPaneListFixture, descendantInspector: inspector)

        #expect(panes.first { $0.id == "%45" } == nil)
    }

    /// Acceptance item 3: the descendant walk for a given `pane_id` runs once and is cached for
    /// the pane's lifetime, not re-run every discovery pass (SPEC §2). Classifies the same
    /// fixture twice against one shared `AgentDetector` — simulating two discovery passes — and
    /// asserts the fallback-eligible pane (`%28`) was walked exactly once. Also pins the
    /// companion cost-saving from this task's negative-signal split: a hostname-titled pane
    /// (`%11`) is never walked at all, excluded before ladder step 2 runs.
    @Test func descendantWalkRunsOnceThenIsCachedAcrossDiscoveryPasses() throws {
        let inspector = FakeDescendantProcessInspector(argvByPID: [8578: ["/usr/local/bin/claude"]])
        let detector = AgentDetector(hostname: fixtureHostname, descendantInspector: inspector)
        let rawPanes = try PaneDiscovery.parse(capturedPaneListFixture)

        _ = detector.classify(rawPanes)
        _ = detector.classify(rawPanes)

        #expect(inspector.callCount(for: 8578) == 1)
        #expect(inspector.callCount(for: 8870) == 0) // %11, hostname-titled — never walked
    }

    /// Regression for the whole-branch review finding that `descendantArgv` was called once per
    /// uncached fallback-eligible pane: `%28` and `%45` both reach ladder step 2 uncached in the
    /// same `classify()` call (the fixture's two empty-titled shell panes), so a naive
    /// implementation would spawn `ps -A` twice in this one pass. The fix batches every
    /// uncached pid needing a walk into a single `descendantArgv(of:)` call per pass.
    @Test func descendantWalkBatchesAllUncachedPanesIntoOneCallPerPass() throws {
        let inspector = FakeDescendantProcessInspector(argvByPID: [8578: ["/usr/local/bin/claude"]])

        _ = try classify(capturedPaneListFixture, descendantInspector: inspector)

        #expect(inspector.batchCallCount == 1)
        #expect(inspector.callCount(for: 8578) == 1) // %28
        #expect(inspector.callCount(for: 32244) == 1) // %45
    }

    /// `ProcessTableDescendantInspector.descendantArgv` returns `[:]` (no pid present, not even
    /// with an empty array) when the underlying `ps -A` snapshot itself fails. A pid *absent*
    /// from the result must not be cached as "walked, no agent descendant" — that would
    /// permanently exclude every uncached pane caught by one failed snapshot. Confirms the walk
    /// is retried on the next discovery pass instead.
    @Test func failedDescendantSnapshotIsNotCachedAndIsRetriedNextPass() throws {
        let inspector = FailingDescendantProcessInspector()
        let detector = AgentDetector(hostname: fixtureHostname, descendantInspector: inspector)
        let rawPanes = try PaneDiscovery.parse(capturedPaneListFixture)

        let firstPass = detector.classify(rawPanes)
        let secondPass = detector.classify(rawPanes)

        #expect(firstPass.first { $0.id == "%28" } == nil)
        #expect(secondPass.first { $0.id == "%28" } == nil)
        #expect(inspector.batchCallCount == 2) // retried both passes, not cached after the first
    }

    // MARK: - TASK-013: corroborate title-matched panes against a live descendant process

    /// Acceptance item 1: `%29` (title `π - rc-billing-advisor`, pid 25236) is a title match,
    /// but its only descendant here is a plain shell tool — no live `pi`/`claude` process.
    /// tmux's sticky `pane_title` (this task's motivating bug) means the title alone is no
    /// longer trustworthy, so the pane must be excluded, not classified.
    @Test func titleMatchedPaneWithNoLiveAgentDescendantIsExcluded() throws {
        let inspector = FakeDescendantProcessInspector(argvByPID: [25236: ["/bin/zsh", "/usr/bin/less"]])

        let panes = try classify(capturedPaneListFixture, descendantInspector: inspector)

        #expect(panes.first { $0.id == "%29" } == nil)
    }

    /// Acceptance item 2 (regression guard): the common case — `cmd=zsh` at the pane's top
    /// level, the agent running as a live child of that shell — still classifies normally. This
    /// is the same shape as `%54`'s captured reality (live investigation: `pi` a child of the
    /// pane's own pid) and must not be broken by adding corroboration.
    @Test func titleMatchedPaneWithLiveAgentDescendantIsStillClassified() throws {
        let inspector = FakeDescendantProcessInspector(argvByPID: [25236: ["/usr/local/bin/pi"]])

        let panes = try classify(capturedPaneListFixture, descendantInspector: inspector)

        let pi = try #require(panes.first { $0.id == "%29" })
        #expect(pi.type == .pi)
    }

    /// Acceptance item 3: when the descendant-process snapshot fails to run for the pane's pid
    /// in a given pass (pid absent from the batch result, `DescendantProcessInspector`'s
    /// documented "walk didn't run" signal), the title-matched pane is NOT demoted — it keeps
    /// its title-based classification for that pass, fail-open, same contract as the
    /// fallback-ladder step.
    @Test func titleMatchedPaneKeepsClassificationWhenSnapshotFails() throws {
        let inspector = FailingDescendantProcessInspector()

        let panes = try classify(capturedPaneListFixture, descendantInspector: inspector)

        #expect(panes.first { $0.id == "%29" } != nil)
    }

    /// Corroboration must run every `classify()` pass, not be memoized for the pane's lifetime
    /// like the fallback ladder's `DescendantWalkCache` — unlike "does this shell wrap an
    /// agent" (stable for the pane's life), "is that agent still alive" can change between
    /// passes. Same `AgentDetector`/pane across two passes: alive on pass 1, dead on pass 2 —
    /// the pane must disappear on pass 2, proving the first pass's result wasn't cached.
    @Test func titleMatchCorroborationIsNotMemoizedAcrossPasses() throws {
        let inspector = FakeDescendantProcessInspector(argvByPID: [25236: ["/usr/local/bin/pi"]])
        let detector = AgentDetector(hostname: fixtureHostname, descendantInspector: inspector)
        let rawPanes = try PaneDiscovery.parse(capturedPaneListFixture)

        let firstPass = detector.classify(rawPanes)
        inspector.setArgv([], for: 25236) // agent process has since exited
        let secondPass = detector.classify(rawPanes)

        #expect(firstPass.first { $0.id == "%29" } != nil)
        #expect(secondPass.first { $0.id == "%29" } == nil)
    }
}

/// Simulates a failed process-table snapshot: `descendantArgv` always returns an empty
/// dictionary, with no pid present — distinct from `FakeDescendantProcessInspector` configured
/// with empty argv, which reports pids as walked-and-empty.
private final class FailingDescendantProcessInspector: DescendantProcessInspector, @unchecked Sendable {
    private var callCounts = 0
    private let lock = NSLock()

    var batchCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return callCounts
    }

    func descendantArgv(of pids: Set<Int32>) -> [Int32: [String]] {
        lock.lock()
        callCounts += 1
        lock.unlock()
        return [:]
    }
}
