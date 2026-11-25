/// Expresses how an `AgentType`'s badge should render — a literal text glyph (Pi's `π`) or an
/// SF Symbol name (Claude Code's `sparkle`) — without `TmuxCore` needing to import AppKit.
/// Mirrors the existing `TileColor` -> `NSColor` split (`ActivityPhase.color`): the rendering
/// *decision* stays headlessly testable here in `TmuxCore`; the actual `NSImage`/`NSTextField`
/// content is resolved once, at the `PaneWatchApp` boundary (`TileCardView`).
public enum BadgeGlyph: Sendable, Equatable {
    case text(String)
    case symbol(name: String)
    /// OMP's full-colour pixel-art gradient π (geometry in `PixelPiGlyph`). Unlike `.symbol`, it
    /// is drawn programmatically and must not be white-tinted.
    case pixelPi
}

/// Geometry of the OMP badge: a 12x11 unit grid (origin top-left, transparent elsewhere) of
/// opaque cells, each carrying its own 0xRRGGBB colour. Kept in `TmuxCore` — AppKit-free — so
/// the shape is headlessly testable; `TileCardView` only rasterizes these cells.
public enum PixelPiGlyph {
    public static let width = 12
    public static let height = 11

    public struct Cell: Equatable, Sendable {
        public let x: Int
        public let y: Int
        public let rgb: UInt32
    }

    public static let cells: [Cell] = topBar + leg(x: 3, bands: leftLeg) + leg(x: 7, bands: rightLeg)

    private static let barStart = 0xE55CC7
    private static let barEnd = 0x8C64EC

    /// y 0-1 across the full width; one colour step per column, each channel interpolated
    /// linearly between the endpoints.
    private static let topBar: [Cell] = (0..<width).flatMap { column in
        let fraction = Double(column) / Double(width - 1)
        let rgb = [16, 8, 0].reduce(0) { packed, shift in
            let from = Double(barStart >> shift & 0xFF)
            let end = Double(barEnd >> shift & 0xFF)
            return packed | Int((from + (end - from) * fraction).rounded()) << shift
        }
        return (0..<2).map { Cell(x: column, y: $0, rgb: UInt32(rgb)) }
    }

    /// Each band is a colour held for `rows` consecutive rows, starting at y 2.
    private static let leftLeg: [(rows: Int, rgb: UInt32)] = [(2, 0xB25FDC), (3, 0x9C62E5), (2, 0x574B91)]
    private static let rightLeg: [(rows: Int, rgb: UInt32)] = [(2, 0x9264E9), (3, 0x7978EA), (2, 0x6495E7), (2, 0x5BB2E4)]

    /// A two-column leg starting at `x`, banded top to bottom from y 2.
    private static func leg(x: Int, bands: [(rows: Int, rgb: UInt32)]) -> [Cell] {
        var cells: [Cell] = []
        var y = 2
        for band in bands {
            for _ in 0..<band.rows {
                cells.append(Cell(x: x, y: y, rgb: band.rgb))
                cells.append(Cell(x: x + 1, y: y, rgb: band.rgb))
                y += 1
            }
        }
        return cells
    }
}
