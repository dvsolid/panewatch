import AppKit
import TmuxCore

/// `card`'s concrete type (see `TileCardView.view`) — overrides `acceptsFirstMouse` so
/// TASK-020's double-click gesture recognizer actually receives clicks. `FloatingPanel.
/// canBecomeKey` is hard-wired `false` (the panel must never steal focus/key status), so it can
/// never become key; AppKit's default for any view in a non-key window is to swallow the first
/// click purely to give the window attention rather than deliver a real `mouseDown`, unless the
/// hit view opts out via this override. Hover (`NSTrackingArea`) was never affected by this —
/// tracking-area events bypass the key-window click-swallowing path entirely — which is why
/// hover always worked while double-click silently never fired.
private final class TileCardContainerView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns one Tile's visual composition — badge, label, task text, translucent glass card
/// material, and the Activity Indicator's pulse. `FloatingPanel`'s sole renderer of a Tile
/// (feature spec § Architecture): keeps glyph resolution, layout math, and
/// `NSVisualEffectView` material setup out of the file that also owns window/scroll/
/// panel-positioning concerns.
///
/// TASK-008: 84x64pt rounded-rect card (feature spec "Compact Card" variant), replacing the
/// old 52pt centered-text square. Left-aligned: an icon+label row, then a dimmer, two-line-
/// clamped task-text row below it. The Activity Phase color lives on a small dot centered on
/// the header row, and (as of TASK-012) also tints the card's own fill at a fixed, phase-
/// uniform low alpha — see `tintLayer` and `phaseTintAlpha`.
///
/// TASK-009: the Blinking phase's dot no longer toggles between two opaque colors — it pulses
/// in *size* (`dotMinSize` <-> `dotMaxSize`) while staying `tile.phase.color` throughout, so
/// SPEC §1's opacity floor holds trivially (opacity is never touched at all). Every other
/// phase keeps a steady dot at `dotSteadySize`, unaffected by `blinkOn`.
///
/// TASK-012: visual polish — the dot centers on the same line the badge/name header row centers
/// on (`headerRowCenterY`), the card is wider (`cardSize.width` 84 -> 100, later 100 -> 120), and
/// the card's `tintLayer` now carries a subtle, static `tile.phase.color` tint alongside its
/// existing hairline/glass chrome.
@MainActor
final class TileCardView {
    /// Ideal size per the feature spec's chosen visual direction. `FloatingPanel` clamps the
    /// *width* actually passed to `init(width:)` down to whatever the scroll view's clip area
    /// has available — under legacy (non-overlay) scrollers that's narrower than this ideal,
    /// since the vertical scroller thickness eats into `contentSize.width` (see `FloatingPanel`
    /// review notes: 130pt panel -> 115pt clip under `.legacy`, not 130pt, minus the 8pt margin
    /// `render(_:)` reserves -> 107pt card, still wider than the pre-widening 100pt ideal). Height
    /// is never adaptive; only width is.
    ///
    /// Widened 84 -> 100pt (TASK-012, acceptance item 3) so task text truncates less
    /// aggressively, then 100 -> 120pt on direct user feedback, each time in step with
    /// `FloatingPanel`'s panel width (92 -> 110 -> 130pt — the two move together: the card
    /// width was already at the exact max that fit under the panel's overlay-scroller clamp
    /// margin each time, so widening the card past its ceiling required widening its container
    /// too). This supersedes the specific 92pt figure from TASK-007's acceptance criteria;
    /// TASK-007's own acceptance ("panel 92pt wide") was itself only ever an input sized to fit
    /// TASK-008's original 84pt card, not an independent constraint.
    ///
    /// TASK-035: height 64 -> 80pt, the same versioned-constant-bump shape as the width history
    /// above — every Tile is still exactly `cardSize.height` tall (no per-instance variation),
    /// so this doesn't touch the "height is never adaptive" meaning of `init(width:)`'s own doc
    /// comment. The added 16pt fits the new Directory Row (`directoryRowHeight` + `rowSpacing`),
    /// whose own row order moved (see `layout(...)`'s doc comment) but whose total footprint
    /// didn't change again after that move. `taskTextHeight` stays fixed at its pre-TASK-035
    /// size so the 2-line clamp is visually unchanged.
    ///
    /// TASK-035 (direct user feedback after first look): width 120 -> 132pt, on request ("make
    /// the tile wider a bit") — the same versioned-constant-bump shape as this property's own
    /// width history above. `FloatingPanel`'s panel width moves with it (138 -> 150pt),
    /// preserving the same 18pt margin between the two the prior 138/120 pair already had.
    static let cardSize = NSSize(width: 132, height: 80)

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
    /// TASK-012: the header row's vertical centerline — badge, name, and the dot all center on
    /// this single value, rather than each being placed independently and hoping they agree.
    /// A `static let` (not width-dependent) since the row's height/position are fixed regardless
    /// of the card's actual (possibly clamped) width.
    private static let headerRowCenterY: CGFloat = cardSize.height - padding - iconLabelRowHeight / 2
    /// The dot's *center* is pinned here regardless of pulse size — replaces TASK-009's
    /// top-right-corner anchor, which kept the dot from drifting during the pulse but placed it
    /// near the card's top-right corner rather than on the header row's centerline, leaving it
    /// visibly misaligned with the badge/name row above it (TASK-012 acceptance item 1). Centering
    /// on a fixed point is a *stronger* anti-drift guarantee than corner-anchoring (the dot's
    /// centroid never moves at all, growing/shrinking symmetrically), while also putting that
    /// centroid exactly on `headerRowCenterY`. Computed from this instance's actual `width` (not
    /// the static `cardSize.width`) so the dot never sits past the card's real right edge when the
    /// card has been clamped narrower.
    private let dotCenter: NSPoint
    /// Matches `toggleBlink`'s own cadence (`defaultBlinkPeriod / 2`) so one grow-or-shrink
    /// animation finishes right as the next toggle fires — a continuous breathing motion, not
    /// a snap followed by a pause. `FloatingPanel` keeps owning the driving `Timer`; this is
    /// purely how one already-delivered `blinkOn` toggle gets rendered smoothly (feature spec
    /// "Considered and rejected": no new timing/driver module).
    private static let pulseDuration = TmuxCore.defaultBlinkPeriod / 2
    private static let rowSpacing: CGFloat = 4
    private static let iconLabelRowHeight: CGFloat = 16
    /// TASK-035: the task-text row's height, fixed rather than "whatever's left above the
    /// bottom padding" (the pre-TASK-035 shape) — it must stay constant now that the Directory
    /// Row claims its own space below it, so the 2-line clamp's actual pixel height (and
    /// therefore its wrapping behavior) is unchanged from before this task.
    private static let taskTextHeight: CGFloat = 28
    /// TASK-035: the Directory Row's fixed height — a single-line label, sized generously for
    /// a 9pt font rather than measured from `intrinsicContentSize` at `init` time, since no
    /// `NSTextField` instance exists yet when `cardSize` (a `static let`) is computed.
    private static let directoryRowHeight: CGFloat = 12
    private static let badgeWidth: CGFloat = 18
    /// TASK-012 (acceptance item 4): how strongly `tintLayer`'s fill carries `tile.phase.color`.
    /// Chosen against the brightest case (`ActivityPhase.blinking`'s saturated orange) so the
    /// tint reads as "subtle" per the acceptance wording rather than overpowering the glass
    /// material/hairline chrome already on the card.
    private static let phaseTintAlpha: CGFloat = 0.16

    /// A square frame of `size`, centered on `center`. `static` and center-parameterized (rather
    /// than reading the instance `dotCenter`) so `init` can call it before `self` is fully
    /// initialized.
    private static func dotFrame(size: CGFloat, center: NSPoint) -> NSRect {
        NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }

    /// Instance-side convenience over the static `dotFrame(size:center:)`, using this card's
    /// actual `dotCenter`. Used everywhere after `init` completes.
    private func dotFrame(size: CGFloat) -> NSRect {
        Self.dotFrame(size: size, center: dotCenter)
    }

    /// For `FloatingPanel` to place in its document view, keyed by `pane_id` exactly as
    /// `tileViewsByID` does today.
    let view: NSView
    private let dot: NSView
    /// TASK-012 (acceptance item 4): the card's translucent Activity-Phase-colored tint, set in
    /// `apply(_:blinkOn:)` as a pure function of `tile.phase.color` — `blinkOn` is never read on
    /// this path, so a `.blinking` Tile's tint is set to the exact same value on every blink
    /// tick and never animates, structurally ruling out the pulsing this item forbids (only
    /// `dot` pulses). Doubles as the hairline-border layer TASK-007/008 already drew here.
    private let tintLayer: NSView
    private let badgeLabel: NSTextField
    private let badgeImageView: NSImageView
    private let nameLabel: NSTextField
    private let taskLabel: NSTextField
    /// TASK-035: the Directory Row — `tile.directoryLabel`'s leaf directory name, light-yellow
    /// per user request, below `taskLabel`.
    private let directoryRowLabel: NSTextField
    /// Tracks the last-applied badge so `apply(_:blinkOn:)` can skip re-resolving the SF
    /// Symbol/text content (and the `badgeLabel`/`badgeImageView` visibility swap) on every
    /// call, matching the existing `stringValue`-diffing pattern for `nameLabel`/`taskLabel`.
    private var appliedBadge: BadgeGlyph?

    /// - Parameter width: this card's actual width, as clamped by `FloatingPanel` to whatever
    ///   the scroll view's clip area has available. Defaults to the ideal `cardSize.width` for
    ///   callers (tests) that don't care about scroller-thickness clamping. Height is always
    ///   `cardSize.height` — never adaptive.
    init(width: CGFloat = cardSize.width) {
        let center = NSPoint(x: width - Self.dotMargin - Self.dotMaxSize / 2, y: Self.headerRowCenterY)
        let card = TileCardContainerView(frame: NSRect(origin: .zero, size: NSSize(width: width, height: Self.cardSize.height)))
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

        // TASK-012: a hairline + Activity-Phase-colored tint on top of the material, so the card
        // boundary reads clearly even where the material's own blend is subtle (e.g. over a dark
        // desktop), and the card itself carries a subtle static hint of its phase color
        // (acceptance item 4). `backgroundColor` starts as the pre-TASK-012 static 6%-white fill
        // as a neutral placeholder only — `apply(_:blinkOn:)` overwrites it with the actual
        // phase-derived tint on the same call that always follows `init` in `FloatingPanel`, so
        // no rendered frame ever shows this placeholder.
        let tint = NSView(frame: card.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        tint.layer?.cornerRadius = Self.cornerRadius
        tint.layer?.masksToBounds = true
        tint.layer?.borderWidth = 1
        tint.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        card.addSubview(tint)

        let badge = NSTextField(labelWithString: "")
        badge.font = .systemFont(ofSize: 13)
        badge.textColor = .white
        badge.lineBreakMode = .byClipping
        card.addSubview(badge)

        // Shares the same badge slot as `badge` (the text field): exactly one of the two is
        // visible at a time, chosen by `tile.badge`'s case in `apply(_:blinkOn:)`. `isTemplate`
        // + `contentTintColor` mirrors the Menu Bar Icon's existing SF Symbol approach
        // (`StatusBarShell`), tinted white to match the badge/name text on this dark card.
        let badgeImage = NSImageView(frame: .zero)
        badgeImage.imageScaling = .scaleProportionallyUpOrDown
        badgeImage.contentTintColor = .white
        badgeImage.isHidden = true
        card.addSubview(badgeImage)

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

        // TASK-035: light yellow per user request — distinct from `name` (white) and `task`
        // (white at 60% alpha), the card's two other text colors, so the Directory Row reads
        // as its own kind of information rather than a dimmer task-text continuation.
        let directoryRow = NSTextField(labelWithString: "")
        directoryRow.font = .systemFont(ofSize: 9)
        directoryRow.textColor = NSColor(calibratedRed: 0.97, green: 0.87, blue: 0.45, alpha: 0.9)
        directoryRow.lineBreakMode = .byTruncatingTail
        card.addSubview(directoryRow)

        let indicator = NSView(frame: Self.dotFrame(size: Self.dotSteadySize, center: center))
        indicator.wantsLayer = true
        // `dotMaxSize / 2` rather than the current frame's own half-width: CALayer clamps a
        // too-large `cornerRadius` down to the largest radius that still fits, so a single
        // fixed value renders a full circle at every size the pulse ever takes (6-8pt) without
        // needing to be kept in sync as `dot.frame` changes size in `apply(_:blinkOn:)`.
        indicator.layer?.cornerRadius = Self.dotMaxSize / 2
        card.addSubview(indicator)

        view = card
        dot = indicator
        tintLayer = tint
        badgeLabel = badge
        badgeImageView = badgeImage
        nameLabel = name
        taskLabel = task
        directoryRowLabel = directoryRow
        dotCenter = center

        // Laid out against the pulse's widest extent, not the steady size, so the badge/name
        // row never touches the dot even at the top of its pulse.
        Self.layout(badge: badge, badgeImage: badgeImage, name: name, task: task, directory: directoryRow, width: width, dotFrame: Self.dotFrame(size: Self.dotMaxSize, center: center))
    }

    /// Applies one Tile's badge/label/task-text, card tint, and Activity Phase dot. The sole
    /// place `blinkOn` affects rendering: a `.blinking` Tile's dot pulses in size between
    /// `dotMinSize` and `dotMaxSize`, animated smoothly over `pulseDuration`; every other
    /// phase shows a steady dot at `dotSteadySize`, snapped there immediately (never
    /// animated) so leaving the Blinking phase never leaves a mid-pulse frame on screen. The
    /// dot's color is always `tile.phase.color` at full opacity — size is the only thing that
    /// ever changes about it. `tintLayer`'s translucent phase-colored background (TASK-012) is
    /// likewise always `tile.phase.color`, but never reads `blinkOn` at all, so it never pulses.
    func apply(_ tile: TileState, blinkOn: Bool) {
        if appliedBadge != tile.badge {
            appliedBadge = tile.badge
            switch tile.badge {
            case .text(let glyph):
                badgeImageView.isHidden = true
                badgeLabel.isHidden = false
                badgeLabel.stringValue = glyph
            case .symbol(let name):
                badgeLabel.isHidden = true
                badgeImageView.isHidden = false
                let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
                image?.isTemplate = true
                badgeImageView.image = image
            }
        }
        if nameLabel.stringValue != tile.label {
            nameLabel.stringValue = tile.label
        }
        let taskText = tile.taskText ?? ""
        if taskLabel.stringValue != taskText {
            taskLabel.stringValue = taskText
        }
        let directoryText = "▸ \(tile.directoryLabel)"
        if directoryRowLabel.stringValue != directoryText {
            directoryRowLabel.stringValue = directoryText
        }

        let phaseColor = NSColor(tile.phase.color)

        // TASK-012 (acceptance item 4): a pure function of `tile.phase.color` alone — `blinkOn`
        // is never consulted here, so a `.blinking` Tile's tint is reassigned the identical
        // value on every blink tick this `apply(_:blinkOn:)` call happens to be part of. A
        // direct (non-`.animator()`) assignment outside the `NSAnimationContext` group below,
        // matching `dot`'s own unconditional color assignment just below it, so this never picks
        // up an implicit animation either. `.fading`'s color legitimately drifts across
        // `probeInterval` renders as `colorFraction` advances — that's the phase's own color
        // changing, not this tint pulsing independently of it.
        tintLayer.layer?.backgroundColor = phaseColor.withAlphaComponent(Self.phaseTintAlpha).cgColor

        dot.layer?.backgroundColor = phaseColor.cgColor

        if case .blinking = tile.phase {
            let size = blinkOn ? Self.dotMaxSize : Self.dotMinSize
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.pulseDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                dot.animator().frame = dotFrame(size: size)
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
            dot.frame = dotFrame(size: Self.dotSteadySize)
        }
    }

    /// Square size given to `badgeImage` (the SF Symbol slot) when centering it on the header
    /// row — an `NSImageView` has no font-derived `intrinsicContentSize` the way the text labels
    /// do, so it needs an explicit height to center rather than one measured from content.
    private static let badgeImageSize: CGFloat = 16

    // swiftlint:disable function_parameter_count
    /// Left-aligned layout: icon+label row at the top (clipped short of the dot centered on
    /// that row), then the task-text row filling the remaining height down to the bottom
    /// padding. `width` is
    /// this card's actual (possibly clamped) width, not the static `cardSize.width`.
    ///
    /// TASK-012 (acceptance item 1): `badge`, `badgeImage`, and `name` are each sized to their
    /// *own* content height and then centered on `headerRowCenterY` — the same centerline the
    /// dot's `dotFrame(size:center:)` centers on — rather than all three sharing one oversized
    /// `iconLabelRowHeight`-tall frame and relying on `NSTextField`'s internal (and, across
    /// different point sizes, inconsistent) vertical text alignment to make them agree. This
    /// makes the alignment a layout invariant instead of an observed-to-look-right guess: a
    /// 13pt badge glyph and a 10pt semibold name never had a reason to optically center the same
    /// way inside an identical 16pt box, but a box sized to each one's own metrics and centered
    /// on a shared line does, by construction. `iconLabelRowHeight` still reserves the same
    /// nominal vertical band it always has (up against `headerRowCenterY`), so the task-text
    /// row below it is unaffected by this change.
    ///
    /// TASK-035: `directory` (the Directory Row) is a third parameter. On direct user feedback
    /// after first look, it sits right below the header row (not bottommost) — `task` moves
    /// down below `directory` instead. `task`'s frame is `taskTextHeight` tall (a fixed
    /// constant) rather than filling every pixel down to the bottom padding, freeing exactly
    /// `directoryRowHeight + rowSpacing` for `directory` between the header row and `task`.
    private static func layout(badge: NSTextField, badgeImage: NSImageView, name: NSTextField, task: NSTextField, directory: NSTextField, width: CGFloat, dotFrame: NSRect) {
        // swiftlint:enable function_parameter_count
        let rowRightEdge = dotFrame.minX - 2
        let centerY = headerRowCenterY

        let badgeHeight = badge.intrinsicContentSize.height
        badge.frame = NSRect(x: padding, y: centerY - badgeHeight / 2, width: badgeWidth, height: badgeHeight)
        badgeImage.frame = NSRect(x: padding, y: centerY - badgeImageSize / 2, width: badgeWidth, height: badgeImageSize)

        let nameHeight = name.intrinsicContentSize.height
        name.frame = NSRect(
            x: padding + badgeWidth,
            y: centerY - nameHeight / 2,
            width: max(rowRightEdge - (padding + badgeWidth), 0),
            height: nameHeight
        )

        let taskY = padding
        task.frame = NSRect(x: padding, y: taskY, width: width - padding * 2, height: taskTextHeight)

        let directoryY = taskY + taskTextHeight + rowSpacing
        directory.frame = NSRect(x: padding, y: directoryY, width: width - padding * 2, height: directoryRowHeight)
    }
}

extension NSColor {
    /// The one point where `TmuxCore`'s AppKit-free `TileColor` (plain RGBA `Double`s) becomes
    /// an `NSColor` — kept in `PaneWatchApp` so `ActivityPhase.color`'s mapping logic stays
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
