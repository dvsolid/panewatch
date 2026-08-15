import Foundation
import Testing
@testable import TmuxCore

/// Exercises `HoverPopupPlacement.frame(forTile:within:size:gap:)` — the pure rect-math half of
/// TASK-014's popup positioning (feature spec § Architecture, `HoverPreviewController`'s "opens
/// toward whichever side of the Tile has room" note). Split out of the AppKit-facing controller
/// specifically so this logic stays unit-testable headlessly, same rationale `NSColor(_
/// tileColor:)` documents for keeping `TmuxCore` AppKit-free.
@Suite struct HoverPopupPlacementTests {
    /// Mirrors `FloatingPanel`'s own pinned-to-the-right-edge posture: the Status Bar panel (and
    /// every Tile inside it) always sits at the screen's right edge, so there is essentially
    /// never room to open the popup on the right — this is the realistic case, not an edge case.
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// Feature spec's fixed popup size (TASK-014 acceptance item 4) — none of the other tests
    /// below check the returned rect's dimensions, only its position, so this is the only test
    /// that would catch a regression to the literal 640x420 size.
    @Test func sizeIsTheFeatureSpecsFixed640By420() {
        #expect(HoverPopupPlacement.size == CGSize(width: 640, height: 420))

        let tile = CGRect(x: 1400, y: 400, width: 120, height: 64)
        let popup = HoverPopupPlacement.frame(forTile: tile, within: screen)

        #expect(popup.size == HoverPopupPlacement.size)
    }

    @Test func opensLeftWhenTileSitsAtTheRightScreenEdge() {
        let tile = CGRect(x: 1400, y: 400, width: 120, height: 64)

        let popup = HoverPopupPlacement.frame(forTile: tile, within: screen)

        #expect(popup.maxX <= tile.minX)
    }

    @Test func opensRightWhenThereIsNoRoomOnTheLeft() {
        let tile = CGRect(x: 0, y: 400, width: 120, height: 64)

        let popup = HoverPopupPlacement.frame(forTile: tile, within: screen)

        #expect(popup.minX >= tile.maxX)
    }

    @Test func clampsAtTopWhenTileIsNearTheScreensTopEdge() {
        let tile = CGRect(x: 1400, y: 880, width: 120, height: 64)

        let popup = HoverPopupPlacement.frame(forTile: tile, within: screen)

        #expect(popup.maxY <= screen.maxY)
    }

    @Test func clampsAtBottomWhenTileIsNearTheScreensBottomEdge() {
        let tile = CGRect(x: 1400, y: 0, width: 120, height: 64)

        let popup = HoverPopupPlacement.frame(forTile: tile, within: screen)

        #expect(popup.minY >= screen.minY)
    }

    @Test func verticallyCentersOnTheTileWhenThereIsRoom() {
        let tile = CGRect(x: 1400, y: 400, width: 120, height: 64)

        let popup = HoverPopupPlacement.frame(forTile: tile, within: screen)

        #expect(abs(popup.midY - tile.midY) < 0.01)
    }

    @Test func resultIsAlwaysFullyOnScreen() {
        // Sweeps tile positions across all four screen edges plus a mid-screen case — the
        // clamp must hold everywhere, not just the single-edge cases above.
        let tiles = [
            CGRect(x: 1400, y: 400, width: 120, height: 64),
            CGRect(x: 0, y: 400, width: 120, height: 64),
            CGRect(x: 700, y: 880, width: 120, height: 64),
            CGRect(x: 700, y: 0, width: 120, height: 64),
            CGRect(x: 700, y: 400, width: 120, height: 64)
        ]

        for tile in tiles {
            let popup = HoverPopupPlacement.frame(forTile: tile, within: screen)
            #expect(screen.contains(popup))
        }
    }
}
