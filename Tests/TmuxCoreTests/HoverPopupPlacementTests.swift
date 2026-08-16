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

    /// The popup's fixed size (`HoverPopupPlacement.size`'s own doc comment has the legibility
    /// investigation behind the 760x620 figure) — none of the other tests below check the
    /// returned rect's dimensions, only its position, so this is the only test that would catch
    /// a regression to a different literal size.
    @Test func sizeIsTheFixed760By620() {
        #expect(HoverPopupPlacement.size == CGSize(width: 760, height: 620))

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

    /// TASK-030 acceptance item 4 (regression check): docking the panel left moves every Tile
    /// near `visibleFrame.minX` instead of `maxX` — the mirror image of the pinned-right posture
    /// every other test in this suite assumes. `HoverPopupPlacement` needs no change for this
    /// (feature spec "Non-goals confirmed": `roomOnRight`/`roomOnLeft` already adapts), so this
    /// pins that non-goal as an executable regression check rather than a comment. The tile
    /// position is derived from `DockSide.frame`, the same geometry `FloatingPanel` would use
    /// once actually docked left, not a hand-picked x.
    @Test func opensFullyOnScreenWhenThePanelIsDockedLeft() {
        let panelFrame = DockSide.frame(width: 138, in: screen, side: .left)
        let tile = CGRect(x: panelFrame.minX + 8, y: 400, width: 120, height: 64)

        let popup = HoverPopupPlacement.frame(forTile: tile, within: screen)

        #expect(popup.minX >= tile.maxX)
        #expect(screen.contains(popup))
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
