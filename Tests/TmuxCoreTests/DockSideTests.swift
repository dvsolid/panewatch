import Foundation
import Testing
@testable import TmuxCore

/// Exercises `DockSide.frame(width:in:side:)` — the pure rect-math half of TASK-030's dock-side
/// geometry (feature spec § Architecture, `DockSide`). Mirrors `HoverPopupPlacementTests`'
/// pattern for headless geometry testing.
@Suite struct DockSideTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func alignsToTheScreensRightEdgeForDockRight() {
        let frame = DockSide.frame(width: 138, in: screen, side: .right)

        #expect(frame.maxX == screen.maxX)
    }

    @Test func alignsToTheScreensLeftEdgeForDockLeft() {
        let frame = DockSide.frame(width: 138, in: screen, side: .left)

        #expect(frame.minX == screen.minX)
    }

    @Test func spansTheVisibleFramesFullHeightRegardlessOfSide() {
        let frame = DockSide.frame(width: 138, in: screen, side: .left)

        #expect(frame.minY == screen.minY)
        #expect(frame.height == screen.height)
    }

    @Test func resolvesToLeftWhenThePanelsCenterIsLeftOfTheScreensMidpoint() {
        let side = DockSide.nearest(panelX: 0, panelWidth: 138, in: screen)

        #expect(side == .left)
    }

    @Test func resolvesToRightWhenThePanelsCenterIsRightOfTheScreensMidpoint() {
        let side = DockSide.nearest(panelX: 1300, panelWidth: 138, in: screen)

        #expect(side == .right)
    }

    @Test func roundTripsAnArbitrarySequenceOfSavesThroughAStore() {
        let store = FakeDockSideStore()

        store.save(.left)
        #expect(store.load() == .left)

        store.save(.right)
        #expect(store.load() == .right)
    }
}

/// In-memory `DockSideStore` conformance for tests — no `UserDefaults` domain touched. The real
/// adapter, `UserDefaultsDockSideStore`, lives in `TmuxerApp`.
private final class FakeDockSideStore: DockSideStore {
    private var side: DockSide = .right

    func load() -> DockSide { side }
    func save(_ side: DockSide) { self.side = side }
}
