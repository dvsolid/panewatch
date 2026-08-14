import AppKit
import TmuxCore

/// A borderless, non-activating panel pinned to the right edge of the main screen.
///
/// Never takes keyboard focus (`canBecomeKey`/`canBecomeMain` both return `false`, on top of
/// `.nonactivatingPanel`'s own default) and floats above all other windows — including across
/// Spaces and full-screen apps, via `collectionBehavior`. Renders one Tile per `TileState`:
/// agent-type badge, label, (for Claude Code) task text (TASK-002/TASK-003), and its live
/// Activity Phase color (TASK-005). This is the one manually-verified piece of TASK-005 — a
/// live color cycling through Blinking/Ready/Fading/Idle isn't unit-testable (feature spec
/// Testing Decisions); `ActivityPhase.color`, which this maps to `NSColor`, is.
@MainActor
final class FloatingPanel: NSPanel {
    /// Tiles scroll rather than resize the panel: the panel's width/side are fixed for this
    /// feature (epic "Out of scope"), and a real machine can easily have more panes than fit
    /// in one screen height (verified manually against this dev machine's ~35 panes).
    private let scrollView = NSScrollView()

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

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        scrollView.frame = content.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        content.addSubview(scrollView)
        contentView = content
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

    /// Rebuilds the Tile list from scratch. Cheap enough for a one-shot render at launch
    /// (TASK-002); live reconciliation without a full rebuild is TASK-006.
    func render(_ tiles: [TileState]) {
        let width = scrollView.contentSize.width
        let tileSize: CGFloat = min(width - 4, 52)
        let spacing: CGFloat = 4
        let contentHeight = max(
            CGFloat(tiles.count) * (tileSize + spacing) + spacing,
            scrollView.contentSize.height
        )
        let document = NSView(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))

        var y = contentHeight - spacing - tileSize
        for tile in tiles {
            document.addSubview(Self.makeTileView(tile, size: tileSize, y: y, width: width))
            y -= (tileSize + spacing)
        }
        scrollView.documentView = document
    }

    private static func makeTileView(_ tile: TileState, size: CGFloat, y: CGFloat, width: CGFloat) -> NSView {
        let box = NSView(frame: NSRect(x: (width - size) / 2, y: y, width: size, height: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(tile.phase.color).cgColor
        box.layer?.cornerRadius = 6

        // Badge on its own line so it stays legible at 9pt even when `label`/`taskText` truncate.
        let text = [tile.badge, tile.label, tile.taskText].compactMap { $0 }.joined(separator: "\n")
        let label = NSTextField(labelWithString: text)
        label.frame = box.bounds.insetBy(dx: 3, dy: 3)
        label.autoresizingMask = [.width, .height]
        label.font = .systemFont(ofSize: 9)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 0
        box.addSubview(label)
        return box
    }

    private static func frame(on screen: NSScreen?) -> NSRect {
        let width: CGFloat = 60
        guard let visible = screen?.visibleFrame else {
            return NSRect(x: 0, y: 0, width: width, height: 400)
        }
        return NSRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height)
    }
}

private extension NSColor {
    /// The one point where `TmuxCore`'s AppKit-free `TileColor` (plain RGBA `Double`s) becomes
    /// an `NSColor` — kept in `TmuxerApp` so `ActivityPhase.color`'s mapping logic stays
    /// unit-testable headlessly (CLAUDE.md).
    convenience init(_ tileColor: TileColor) {
        self.init(
            red: CGFloat(tileColor.red),
            green: CGFloat(tileColor.green),
            blue: CGFloat(tileColor.blue),
            alpha: CGFloat(tileColor.alpha)
        )
    }
}
