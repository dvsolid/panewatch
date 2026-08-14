import AppKit
import TmuxCore

/// Owns one Tile's visual composition — badge, label, task text, translucent glass card
/// material, and (later, TASK-009) the Activity Indicator's pulse. `FloatingPanel`'s sole
/// renderer of a Tile (feature spec § Architecture): keeps glyph resolution, layout math, and
/// `NSVisualEffectView` material setup out of the file that also owns window/scroll/
/// panel-positioning concerns.
///
/// TASK-008: 84x64pt rounded-rect card (feature spec "Compact Card" variant), replacing the
/// old 52pt centered-text square. Left-aligned: an icon+label row, then a dimmer, two-line-
/// clamped task-text row below it. The Activity Phase color lives on a small corner dot, not
/// the card's fill — the dot always renders a fully-opaque color (SPEC §1's opacity floor):
/// a "blinked off" Tile toggles the dot between two opaque colors, never dims it.
@MainActor
final class TileCardView {
    /// Fixed per the feature spec's chosen visual direction — not adaptive to available width,
    /// unlike the old square Tile's `min(width - 4, 52)`.
    static let cardSize = NSSize(width: 84, height: 64)

    private static let cornerRadius: CGFloat = 10
    private static let padding: CGFloat = 8
    private static let dotSize: CGFloat = 7
    private static let dotMargin: CGFloat = 6
    private static let rowSpacing: CGFloat = 4
    private static let iconLabelRowHeight: CGFloat = 16
    private static let badgeWidth: CGFloat = 18

    /// Fully opaque near-black — SPEC §1: "Opacity never drops below 100%, at any phase,
    /// forever," so the blink's "off" half toggles the dot to a different opaque color rather
    /// than dimming it. Not `ActivityPhase.grey` (`.idle`'s color): a blinking Tile flashing
    /// through idle's exact hue twice a second would read as a second, unrelated phase.
    private static let blinkOffColor = NSColor(white: 0.08, alpha: 1.0)

    /// For `FloatingPanel` to place in its document view, keyed by `pane_id` exactly as
    /// `tileViewsByID` does today.
    let view: NSView
    private let dot: NSView
    private let badgeLabel: NSTextField
    private let nameLabel: NSTextField
    private let taskLabel: NSTextField

    init() {
        let card = NSView(frame: NSRect(origin: .zero, size: Self.cardSize))
        card.wantsLayer = true
        card.layer?.cornerRadius = Self.cornerRadius
        card.layer?.masksToBounds = true

        // Glass card background: same `.hudWindow` material family as the panel
        // (`FloatingPanel`), but `.withinWindow` blending so it composites against the panel's
        // own material already drawn behind it, rather than the desktop — a card that reads as
        // sitting on the panel's glass, visibly distinct from the panel's own fill.
        let effect = NSVisualEffectView(frame: card.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = Self.cornerRadius
        effect.layer?.masksToBounds = true
        card.addSubview(effect)

        // A faint tint + hairline on top of the material so the card boundary reads clearly
        // even where the material's own blend is subtle (e.g. over a dark desktop).
        let overlay = NSView(frame: card.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        overlay.layer?.cornerRadius = Self.cornerRadius
        overlay.layer?.masksToBounds = true
        overlay.layer?.borderWidth = 1
        overlay.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        card.addSubview(overlay)

        let badge = NSTextField(labelWithString: "")
        badge.font = .systemFont(ofSize: 13)
        badge.textColor = .white
        badge.lineBreakMode = .byClipping
        card.addSubview(badge)

        let name = NSTextField(labelWithString: "")
        name.font = .systemFont(ofSize: 10, weight: .semibold)
        name.textColor = .white
        name.lineBreakMode = .byTruncatingTail
        card.addSubview(name)

        let task = NSTextField(labelWithString: "")
        task.font = .systemFont(ofSize: 9)
        task.textColor = NSColor.white.withAlphaComponent(0.6)
        task.lineBreakMode = .byTruncatingTail
        task.maximumNumberOfLines = 2
        task.usesSingleLineMode = false
        task.cell?.wraps = true
        card.addSubview(task)

        let indicator = NSView(frame: NSRect(
            x: Self.cardSize.width - Self.dotMargin - Self.dotSize,
            y: Self.cardSize.height - Self.dotMargin - Self.dotSize,
            width: Self.dotSize,
            height: Self.dotSize
        ))
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = Self.dotSize / 2
        card.addSubview(indicator)

        view = card
        dot = indicator
        badgeLabel = badge
        nameLabel = name
        taskLabel = task

        Self.layout(badge: badge, name: name, task: task, dotFrame: indicator.frame)
    }

    /// Applies one Tile's badge/label/task-text and Activity Phase color. The sole place
    /// `blinkOn` affects rendering: `.blinking` Tiles alternate their dot between
    /// `ActivityPhase.color` and `Self.blinkOffColor`; every other phase always shows its
    /// `ActivityPhase.color` steadily. Both colors are fully opaque, so the dot never dims.
    func apply(_ tile: TileState, blinkOn: Bool) {
        if badgeLabel.stringValue != tile.badge {
            badgeLabel.stringValue = tile.badge
        }
        if nameLabel.stringValue != tile.label {
            nameLabel.stringValue = tile.label
        }
        let taskText = tile.taskText ?? ""
        if taskLabel.stringValue != taskText {
            taskLabel.stringValue = taskText
        }

        let showOn: Bool
        if case .blinking = tile.phase { showOn = blinkOn } else { showOn = true }
        dot.layer?.backgroundColor = (showOn ? NSColor(tile.phase.color) : Self.blinkOffColor).cgColor
    }

    /// Left-aligned layout: icon+label row at the top (clipped short of the corner dot), then
    /// the task-text row filling the remaining height down to the bottom padding.
    private static func layout(badge: NSTextField, name: NSTextField, task: NSTextField, dotFrame: NSRect) {
        let width = cardSize.width
        let height = cardSize.height
        let rowRightEdge = dotFrame.minX - 2
        let rowY = height - padding - iconLabelRowHeight

        badge.frame = NSRect(x: padding, y: rowY, width: badgeWidth, height: iconLabelRowHeight)
        name.frame = NSRect(
            x: padding + badgeWidth,
            y: rowY,
            width: max(rowRightEdge - (padding + badgeWidth), 0),
            height: iconLabelRowHeight
        )

        let taskY = padding
        let taskHeight = max(rowY - rowSpacing - taskY, 0)
        task.frame = NSRect(x: padding, y: taskY, width: width - padding * 2, height: taskHeight)
    }
}

extension NSColor {
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
