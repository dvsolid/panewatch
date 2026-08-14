import Testing
@testable import TmuxCore

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

private func classify(_ output: String) throws -> [AgentPane] {
    try AgentDetector().classify(PaneDiscovery.parse(output))
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
        #expect(pi.type.badge == "π")
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

    /// Acceptance item 6: a pane whose title matches neither a title pattern nor an explicit
    /// negative signal (non-empty, non-hostname title; command outside the shell/ssh/ngrok
    /// set) is excluded rather than shown as an unknown/ambiguous Tile — the conservative
    /// default from this task's Slice, since the descendant-process fallback that would
    /// otherwise adjudicate it isn't wired until TASK-004.
    @Test func ambiguousPaneMatchingNeitherPatternNorNegativeSignalIsExcluded() throws {
        let panes = try classify(capturedPaneListFixture + "\n" + ambiguousPaneRow)

        #expect(panes.first { $0.id == "%99" } == nil)
    }
}
