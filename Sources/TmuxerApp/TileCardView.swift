import AppKit
import TmuxCore

/// Owns one Tile's visual composition — badge, label, task text, translucent glass card
/// material, and the Activity Indicator's pulse. `FloatingPanel`'s sole renderer of a Tile
/// (feature spec § Architecture): keeps glyph resolution, layout math, and
/// `NSVisualEffectView` material setup out of the file that also owns window/scroll/
/// panel-positioning concerns.
///
/// TASK-008: 84x64pt rounded-rect card (feature spec "Compact Card" variant), replacing the
/// old 52pt centered-text square. Left-aligned: an icon+label row, then a dimmer, two-line-
/// clamped task-text row below it. The Activity Phase color lives on a small corner dot, not
/// the card's fill.
///
/// TASK-009: the Blinking phase's dot no longer toggles between two opaque colors — it pulses
/// in *size* (`dotMinSize` <-> `dotMaxSize`) while staying `tile.phase.color` throughout, so
/// SPEC §1's opacity floor holds trivially (opacity is never touched at all). Every other
/// phase keeps a steady dot at `dotSteadySize`, unaffected by `blinkOn`.
@MainActor
final class TileCardView {
    /// Fixed per the feature spec's chosen visual direction — not adaptive to available width,
    /// unlike the old square Tile's `min(width - 4, 52)`.
    static let cardSize = NSSize(width: 84, height: 64)

    private static let cornerRadius: CGFloat = 10
    private static let padding: CGFloat = 8
    /// Steady (non-blinking-phase) dot diameter — unchanged from TASK-008.
    private static let dotSteadySize: CGFloat = 7
    /// TASK-009 pulse extremes: the Blinking dot alternates between these on every
    /// `blinkOn` toggle, straddling `dotSteadySize` so the pulse reads as "the same dot,
    /// breathing" rather than a differently-sized dot appearing.
    private static let dotMinSize: CGFloat = 6
    private static let dotMaxSize: CGFloat = 8
    private static let dotMargin: CGFloat = 6
    /// The dot's top-right corner is pinned here regardless of size, so growing/shrinking
    /// reads as a pulse anchored to the tile's corner rather than a dot that drifts.
    private static let dotAnchor = NSPoint(x: cardSize.width - dotMargin, y: cardSize.height - dotMargin)
    /// Matches `toggleBlink`'s own cadence (`defaultBlinkPeriod / 2`) so one grow-or-shrink
    /// animation finishes right as the next toggle fires — a continuous breathing motion, not
    /// a snap followed by a pause. `FloatingPanel` keeps owning the driving `Timer`; this is
    /// purely how one already-delivered `blinkOn` toggle gets rendered smoothly (feature spec
    /// "Considered and rejected": no new timing/driver module).
    private static let pulseDuration = TmuxCore.defaultBlinkPeriod / 2
    private static let rowSpacing: CGFloat = 4
    private static let iconLabelRowHeight: CGFloat = 16
    private static let badgeWidth: CGFloat = 18

    /// A square frame of `size`, anchored so `dotAnchor` is always its top-right corner.
    private static func dotFrame(size: CGFloat) -> NSRect {
        NSRect(x: dotAnchor.x - size, y: dotAnchor.y - size, width: size, height: size)
    }

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

        let indicator = NSView(frame: Self.dotFrame(size: Self.dotSteadySize))
        indicator.wantsLayer = true
        // `dotMaxSize / 2` rather than the current frame's own half-width: CALayer clamps a
        // too-large `cornerRadius` down to the largest radius that still fits, so a single
        // fixed value renders a full circle at every size the pulse ever takes (6-8pt) without
        // needing to be kept in sync as `dot.frame` changes size in `apply(_:blinkOn:)`.
        indicator.layer?.cornerRadius = Self.dotMaxSize / 2
        card.addSubview(indicator)

        view = card
        dot = indicator
        badgeLabel = badge
        nameLabel = name
        taskLabel = task

        // Laid out against the pulse's widest extent, not the steady size, so the badge/name
        // row never touches the dot even at the top of its pulse.
        Self.layout(badge: badge, name: name, task: task, dotFrame: Self.dotFrame(size: Self.dotMaxSize))
    }

    /// Applies one Tile's badge/label/task-text and Activity Phase color. The sole place
    /// `blinkOn` affects rendering: a `.blinking` Tile's dot pulses in size between
    /// `dotMinSize` and `dotMaxSize`, animated smoothly over `pulseDuration`; every other
    /// phase shows a steady dot at `dotSteadySize`, snapped there immediately (never
    /// animated) so leaving the Blinking phase never leaves a mid-pulse frame on screen. The
    /// dot's color is always `tile.phase.color` at full opacity — size is the only thing that
    /// ever changes about it.
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

        dot.layer?.backgroundColor = NSColor(tile.phase.color).cgColor

        if case .blinking = tile.phase {
            let size = blinkOn ? Self.dotMaxSize : Self.dotMinSize
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.pulseDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dot.animator().frame = Self.dotFrame(size: size)
            }
        } else if dot.frame.size.width != Self.dotSteadySize {
            // `removeAllAnimations()` + a direct (non-`.animator()`) assignment: explicitly
            // discard any pulse animation still in flight from the phase this Tile just left,
            // then snap immediately — acceptance item 4: no leftover mid-pulse frame visible
            // on a now-steady dot. A bare direct assignment already interrupts an in-flight
            // `.animator()`-driven animation under AppKit's own animation architecture
            // (verified empirically: a probe using an equivalent layer-backed `NSView` showed
            // `layer.presentation()!.frame` snapping to the direct-set value immediately, with
            // no continued interpolation toward the canceled animation's target — see
            // Implementation notes); `removeAllAnimations()` makes that guarantee explicit in
            // the code rather than resting on the animator-interrupt behavior alone.
            dot.layer?.removeAllAnimations()
            dot.frame = Self.dotFrame(size: Self.dotSteadySize)
        }
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
