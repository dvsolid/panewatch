import AppKit
import TmuxCore

/// TASK-039: the OMP badge, rasterized from `PixelPiGlyph`'s cells as crisp filled rects (no
/// antialiasing/interpolation) — drawn rather than bundled, since the app runs as a bare
/// `.build/debug` binary with no resources. Sized at one point per cell (12x11pt), which is how
/// `TileCardView.badgeImageView` shows it (`.scaleNone`); the drawing handler re-runs per
/// backing scale, so the cells stay sharp on Retina.
@MainActor
enum PixelPiImage {
    static let shared: NSImage = {
        let image = NSImage(size: NSSize(width: PixelPiGlyph.width, height: PixelPiGlyph.height), flipped: true) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            context.shouldAntialias = false
            context.imageInterpolation = .none
            let unitWidth = rect.width / CGFloat(PixelPiGlyph.width)
            let unitHeight = rect.height / CGFloat(PixelPiGlyph.height)
            for cell in PixelPiGlyph.cells {
                NSColor(
                    srgbRed: CGFloat(cell.rgb >> 16 & 0xFF) / 255,
                    green: CGFloat(cell.rgb >> 8 & 0xFF) / 255,
                    blue: CGFloat(cell.rgb & 0xFF) / 255,
                    alpha: 1
                ).setFill()
                NSRect(x: CGFloat(cell.x) * unitWidth, y: CGFloat(cell.y) * unitHeight, width: unitWidth, height: unitHeight).fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }()
}
