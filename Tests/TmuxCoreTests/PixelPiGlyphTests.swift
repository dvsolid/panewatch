import Testing
@testable import TmuxCore

/// TASK-039: the OMP badge's geometry lives in `TmuxCore` (AppKit-free) so the shape and
/// gradient are testable headlessly; `TileCardView` only rasterizes the cells.
@Suite struct PixelPiGlyphTests {
    private func color(x: Int, y: Int) -> UInt32? {
        PixelPiGlyph.cells.first { $0.x == x && $0.y == y }?.rgb
    }

    @Test func gridIsTwelveByEleven() {
        #expect(PixelPiGlyph.width == 12)
        #expect(PixelPiGlyph.height == 11)
        #expect(PixelPiGlyph.cells.allSatisfy { $0.x >= 0 && $0.x < 12 && $0.y >= 0 && $0.y < 11 })
    }

    @Test func topBarSpansFullWidthWithLeftToRightGradient() {
        #expect(color(x: 0, y: 0) == 0xE55CC7)
        #expect(color(x: 11, y: 0) == 0x8C64EC)
        #expect(color(x: 0, y: 1) == 0xE55CC7)
        #expect(color(x: 11, y: 1) == 0x8C64EC)
        // Monotone interpolation: the middle column lies strictly between the endpoints.
        let mid = color(x: 5, y: 0)
        #expect(mid != nil && mid != 0xE55CC7 && mid != 0x8C64EC)
    }

    @Test func legsHaveGeometryAndColoursFromTheReference() {
        // Left leg: x 3-4, ends at y 8 with the dim foot.
        #expect(color(x: 3, y: 2) == 0xB25FDC)
        #expect(color(x: 4, y: 6) == 0x9C62E5)
        #expect(color(x: 3, y: 8) == 0x574B91)
        #expect(color(x: 3, y: 9) == nil)
        // Right leg: x 7-8, longer, ends at y 10.
        #expect(color(x: 8, y: 2) == 0x9264E9)
        #expect(color(x: 7, y: 5) == 0x7978EA)
        #expect(color(x: 7, y: 8) == 0x6495E7)
        #expect(color(x: 8, y: 10) == 0x5BB2E4)
        #expect(color(x: 7, y: 11) == nil)
    }

    @Test func everyOtherCellBelowTheBarIsTransparent() {
        let legColumns: Set<Int> = [3, 4, 7, 8]
        let below = PixelPiGlyph.cells.filter { $0.y >= 2 }
        #expect(below.allSatisfy { legColumns.contains($0.x) })
        #expect(below.count == 2 * 7 + 2 * 9)
    }
}
