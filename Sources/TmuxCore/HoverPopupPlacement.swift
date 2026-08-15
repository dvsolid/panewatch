import CoreGraphics

/// Pure rect math for TASK-014's Hover Preview Popup positioning — split out of
/// `HoverPreviewController` (`TmuxerApp`, AppKit-facing and not unit-testable) specifically so
/// this half stays headlessly testable, the same rationale `NSColor(_ tileColor:)`'s doc comment
/// gives for keeping `TmuxCore` AppKit-free (CLAUDE.md). `CGRect`/`CGSize` are CoreGraphics, not
/// AppKit, so this needs no `import AppKit` and no new `Package.swift` dependency.
public enum HoverPopupPlacement {
    /// Feature spec's fixed popup size (TASK-014 acceptance item 4) — not resizable. Bumped
    /// from the original 420x260 to 640x420 so a smaller terminal font
    /// (`PreviewClient.terminalView.font`) actually buys more visible rows/cols instead of just
    /// more padding, then bumped again here to 760x620 on direct user feedback wanting more
    /// visible content per preview. The terminal's font stays fixed regardless of this size —
    /// when a real tmux window has more rows than this box fits at that font,
    /// `PreviewClient.sizeTerminal(toWindowRows:)` grows the terminal view past it and clips the
    /// overflow rather than shrinking the font; see that method's doc comment for why an
    /// earlier version tried shrinking the font to fit instead, and why that was abandoned.
    public static let size = CGSize(width: 760, height: 620)

    /// Gap between a Tile's edge and the popup. Kept small on purpose: `HoverPreviewController`
    /// cancels its close-grace timer on entering either the Tile or the popup, and a small gap
    /// keeps the mouse's Tile-to-popup traverse comfortably inside that grace window (feature
    /// spec: "moving from the Tile directly into the popup does not close it").
    public static let gap: CGFloat = 4

    /// Computes the popup's frame for a Tile at `tileFrame` (screen coordinates), given the
    /// screen's `visibleFrame`. Prefers opening on whichever horizontal side of the Tile has
    /// room for the full popup width; since the Status Bar panel is pinned to the screen's right
    /// edge (`FloatingPanel.frame(on:)`), every Tile lives near `visibleFrame.maxX`, so in
    /// practice this almost always resolves to opening left. Vertically centers on the Tile.
    /// The result is always clamped fully inside `visibleFrame` on every edge, even when the
    /// preferred side doesn't have the full popup width available.
    public static func frame(
        forTile tileFrame: CGRect,
        within visibleFrame: CGRect,
        size: CGSize = HoverPopupPlacement.size,
        gap: CGFloat = HoverPopupPlacement.gap
    ) -> CGRect {
        let roomOnRight = visibleFrame.maxX - tileFrame.maxX
        let roomOnLeft = tileFrame.minX - visibleFrame.minX
        let opensRight = roomOnRight >= size.width + gap || roomOnRight >= roomOnLeft

        let x = opensRight ? tileFrame.maxX + gap : tileFrame.minX - gap - size.width
        let y = tileFrame.midY - size.height / 2

        let clampedX = min(max(x, visibleFrame.minX), visibleFrame.maxX - size.width)
        let clampedY = min(max(y, visibleFrame.minY), visibleFrame.maxY - size.height)

        return CGRect(x: clampedX, y: clampedY, width: size.width, height: size.height)
    }
}
