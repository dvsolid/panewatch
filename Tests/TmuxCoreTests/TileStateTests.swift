import Testing
@testable import TmuxCore

/// Exercises `TileState.directoryLabel` (TASK-035 acceptance item 3, feature spec §
/// Architecture). Reuses `AgentDetectorTests`'s `classify(_:)` helper (fixture + fake
/// descendants) rather than hand-rolling an `AgentPane` — `AgentPane.init` is
/// `fileprivate` to `AgentDetector.swift`, so classification is the only way to get one.
@Suite struct TileStateTests {
    /// `%29` (Pi, title-matched) carries `currentPath`
    /// `/Users/user/Projects/acme/widget-advisor` in `capturedPaneListFixture` — its Tile's
    /// `directoryLabel` must be the leaf name, matching `DirectoryLabel.brief(of:)` directly.
    @Test func directoryLabelIsTheLeafNameOfThePanesCurrentPath() throws {
        let pi = try #require(try classify(capturedPaneListFixture).first { $0.id == "%29" })

        let tile = TileState(pane: pi, phase: .ready)

        #expect(tile.directoryLabel == "widget-advisor")
    }

    /// `%9` is Claude Code, not Pi — `directoryLabel` is populated for every `AgentType`,
    /// not just the type task text happens to be scoped to.
    @Test func directoryLabelIsPopulatedForNonPiAgentTypesToo() throws {
        let claude = try #require(try classify(capturedPaneListFixture).first { $0.id == "%9" })

        let tile = TileState(pane: claude, phase: .ready)

        #expect(tile.directoryLabel == "ops-automation")
    }
}
