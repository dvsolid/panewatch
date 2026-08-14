import AppKit

/// A borderless, non-activating panel pinned to the right edge of the main screen.
///
/// Never takes keyboard focus (`canBecomeKey`/`canBecomeMain` both return `false`, on top of
/// `.nonactivatingPanel`'s own default) and floats above all other windows — including across
/// Spaces and full-screen apps, via `collectionBehavior`. Empty of real content for this slice
/// (TASK-001); Tile rendering lands in TASK-002.
@MainActor
final class FloatingPanel: NSPanel {
    init() {
        super.init(
            contentRect: FloatingPanel.frame(on: NSScreen.main),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.85)
        hasShadow = true
        contentView = NSView(frame: NSRect(origin: .zero, size: frame.size))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the panel if hidden, hides it if shown. Recomputes the frame each time it's
    /// shown so it stays correctly positioned even if the screen configuration changed while
    /// hidden.
    func toggleVisibility() {
        if isVisible {
            orderOut(nil)
        } else {
            setFrame(FloatingPanel.frame(on: NSScreen.main), display: true)
            orderFrontRegardless()
        }
    }

    private static func frame(on screen: NSScreen?) -> NSRect {
        let width: CGFloat = 60
        guard let visible = screen?.visibleFrame else {
            return NSRect(x: 0, y: 0, width: width, height: 400)
        }
        return NSRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height)
    }
}
