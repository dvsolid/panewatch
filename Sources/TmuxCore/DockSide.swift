import CoreGraphics

/// The Status Bar panel's current screen-edge attachment. Pure `.left`/`.right` plus the
/// aligned-frame geometry for each side — mirrors `HoverPopupPlacement`'s split of rect math
/// from its AppKit caller (`FloatingPanel.frame(on:side:)`). Feature spec § Architecture,
/// `DockSide`.
///
/// `nearest(panelX:panelWidth:in:)` (the drag-release side decision) is TASK-031's addition,
/// not this one — TASK-030's slice is menu-driven docking only.
public enum DockSide: String, Equatable {
    case left
    case right

    /// The panel's frame for this side within the given visible screen area, spanning the
    /// visible frame's full height. `.right` matches `FloatingPanel.frame(on:)`'s original
    /// hardcoded `visibleFrame.maxX - width` position; `.left` mirrors it at
    /// `visibleFrame.minX`.
    public static func frame(width: CGFloat, in visibleFrame: CGRect, side: DockSide) -> CGRect {
        let x: CGFloat
        switch side {
        case .left:
            x = visibleFrame.minX
        case .right:
            x = visibleFrame.maxX - width
        }
        return CGRect(x: x, y: visibleFrame.minY, width: width, height: visibleFrame.height)
    }

    /// Resolves which edge is nearest given the panel's current x-position mid-drag —
    /// `panelX` is the panel's left-edge origin, same convention `frame(width:in:side:)`
    /// returns. Compares the panel's *center* (not its left edge) against the visible
    /// frame's horizontal midpoint, so a wide panel docks based on where its bulk actually
    /// sits rather than where its leading edge happens to be. TASK-031.
    public static func nearest(panelX: CGFloat, panelWidth: CGFloat, in visibleFrame: CGRect) -> DockSide {
        let panelCenterX = panelX + panelWidth / 2
        return panelCenterX < visibleFrame.midX ? .left : .right
    }
}
