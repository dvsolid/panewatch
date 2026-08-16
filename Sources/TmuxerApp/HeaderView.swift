import AppKit

/// The Status Bar's drag surface — replaces the previously inert decorative header `NSView`
/// with one that owns `mouseDown`/`mouseDragged`/`mouseUp` pointer tracking, turning the
/// Header into the way a user redocks the panel by hand (feature spec § Architecture,
/// `HeaderView`). Kept separate from `FloatingPanel`'s own window/scroll/positioning scope —
/// mirrors the `TileCardView` split (a dedicated view owns its own interaction/composition).
///
/// Manually verified only, same precedent as `HoverPreviewController` (SPEC.md) — AppKit
/// pointer tracking has no headless test seam in this codebase.
final class HeaderView: NSView {
    /// Fires on every `mouseDragged` with the panel's would-be new x-origin (left edge, same
    /// convention `DockSide.frame`/`FloatingPanel.frame(on:side:)` use). The caller decides
    /// what to do with it — `FloatingPanel` moves its own frame live.
    var onDrag: ((_ proposedX: CGFloat) -> Void)?
    /// Fires once on `mouseUp`. The caller resolves the nearest side (`DockSide.nearest`),
    /// jumps the panel there, and persists it — this view knows nothing about `DockSide`.
    var onDragEnd: (() -> Void)?

    /// Screen-space mouse x at `mouseDown`, so `mouseDragged` can compute a delta independent
    /// of the view's own (moving) coordinate space.
    private var dragOriginMouseX: CGFloat = 0
    /// The window's frame x-origin at `mouseDown` — the delta is added to this, not to
    /// wherever the window happens to be by the time a later `mouseDragged` fires, so drag
    /// tracking stays correct even though the window itself moves mid-drag.
    private var dragOriginPanelX: CGFloat = 0

    /// Set the first time `mouseDragged` actually fires during the current mouseDown/mouseUp
    /// sequence. Gates `onDragEnd` so a plain click (mouseDown immediately followed by mouseUp,
    /// no movement in between) is a no-op instead of redocking the panel — see `mouseUp`.
    private var didDrag = false

    /// `FloatingPanel.canBecomeKey`/`canBecomeMain` are hard-`false` and the panel is
    /// `.nonactivatingPanel`, so the window is never key. AppKit's default for any view in a
    /// non-key window is to swallow the first click purely to give the window attention rather
    /// than deliver a real `mouseDown`, unless the hit view opts out via this override — same
    /// bug and same fix as `TileCardContainerView.acceptsFirstMouse` (`TileCardView.swift`,
    /// commit `32fcacf`). Without it, `mouseDown`/`mouseDragged`/`mouseUp` never reach this view
    /// on the app's normal (non-activating, `.accessory`-policy) path, so the header can never
    /// start a drag.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The Header carries purely decorative subviews (icon, label, tint, divider) added by
    /// `FloatingPanel`. Without this override, a mouseDown landing on one of those subviews'
    /// frames would be dispatched to it instead of `HeaderView`, and (being non-interactive
    /// views that don't forward unhandled mouse events up the responder chain) the drag would
    /// silently never start. Routing every hit inside our own bounds to `self` makes the whole
    /// Header one uniform drag surface regardless of what's layered on top of it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        dragOriginMouseX = NSEvent.mouseLocation.x
        dragOriginPanelX = window?.frame.origin.x ?? 0
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        let deltaX = NSEvent.mouseLocation.x - dragOriginMouseX
        onDrag?(dragOriginPanelX + deltaX)
    }

    override func mouseUp(with event: NSEvent) {
        // A bare click (no `mouseDragged` in between) must not redock the panel — `onDragEnd`
        // resolves the nearest side and persists it, which would otherwise fire on every plain
        // click now that `acceptsFirstMouse` lets mouseDown reach this view at all.
        guard didDrag else { return }
        onDragEnd?()
    }
}
