import Testing
@testable import TmuxCore

/// TASK-039: OMP (Oh My Pi) shares Pi's `π` title prefix, so classification hinges on the
/// corroborating descendant. Reuses `AgentDetectorTests.swift`'s `classify` helper.
/// Canned process table: argv per pid, or (`failing`) a snapshot that never runs — the
/// "pid absent from the batch" signal `DescendantProcessInspector` documents.
private struct CannedDescendants: DescendantProcessInspector {
    var argvByPID: [Int32: [String]] = [:]
    var failing = false

    func descendantArgv(of pids: Set<Int32>) -> [Int32: [String]] {
        failing ? [:] : Dictionary(uniqueKeysWithValues: pids.map { ($0, argvByPID[$0] ?? []) })
    }
}

@Suite struct AgentDetectorOmpTests {
    /// OMP brands its tmux title with Pi's `π` prefix, so the title alone says Pi. `%29` is a
    /// `π`-titled pane whose corroborating descendant is the bare `omp` executable: the
    /// descendant's type must win, or OMP would render as Pi.
    @Test func piTitledPaneWithOmpDescendantIsClassifiedAsOmp() throws {
        let inspector = CannedDescendants(argvByPID: [25236: ["omp"]])

        let panes = try classify(capturedPaneListFixture, descendantInspector: inspector)

        let omp = try #require(panes.first { $0.id == "%29" })
        #expect(omp.type == .omp)
        #expect(omp.taskText == nil)
    }

    /// Regression guard for the disambiguation: a `π`-titled pane whose descendant is `pi`
    /// stays `.pi`.
    @Test func piTitledPaneWithPiDescendantStaysPi() throws {
        let inspector = CannedDescendants(argvByPID: [25236: ["/usr/local/bin/pi"]])

        let panes = try classify(capturedPaneListFixture, descendantInspector: inspector)

        #expect(try #require(panes.first { $0.id == "%29" }).type == .pi)
    }

    /// A `π`-titled pane whose snapshot failed fails open to the title's type (`.pi`) — the
    /// disambiguation needs a descendant to read, and absent one the title is all there is.
    @Test func piTitledPaneKeepsPiWhenSnapshotFails() throws {
        let panes = try classify(capturedPaneListFixture, descendantInspector: CannedDescendants(failing: true))

        #expect(try #require(panes.first { $0.id == "%29" }).type == .pi)
    }

    /// An unbranded pane (no title signal) with an `omp` descendant classifies as `.omp` via
    /// the fallback walk. `%45` (empty title, `zsh`) is otherwise unused for a positive match.
    @Test func unbrandedPaneWithOmpProcessInDescendantsIsClassifiedAsOmp() throws {
        let inspector = CannedDescendants(argvByPID: [32244: ["omp"]])

        let panes = try classify(capturedPaneListFixture, descendantInspector: inspector)

        #expect(try #require(panes.first { $0.id == "%45" }).type == .omp)
    }

    /// Basename equality, not substring: `ompd` or `romp` must not match `omp`.
    @Test func processNamesContainingOmpAsSubstringDoNotMatch() throws {
        let inspector = CannedDescendants(argvByPID: [32244: ["/usr/bin/romp", "ompd"]])

        let panes = try classify(capturedPaneListFixture, descendantInspector: inspector)

        #expect(panes.first { $0.id == "%45" } == nil)
    }

    @Test func ompBadgeIsPixelPiGlyph() throws {
        #expect(AgentType.omp.badge == .pixelPi)
    }
}
