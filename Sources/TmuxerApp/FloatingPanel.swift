import AppKit
import TmuxCore

/// A borderless, non-activating panel pinned to the right edge of the main screen.
///
/// Never takes keyboard focus (`canBecomeKey`/`canBecomeMain` both return `false`, on top of
/// `.nonactivatingPanel`'s own default) and floats above all other windows — including across
/// Spaces and full-screen apps, via `collectionBehavior`. Owns window/scroll/panel-positioning
/// concerns only; each rendered Tile's own visual composition (badge, label, task text, glass
/// card material, Activity Phase dot) is `TileCardView`'s (TASK-008), one instance per Tile,
/// keyed by `pane_id`. This is the one manually-verified piece of the live Activity Phase
/// cycling through Blinking/Ready/Fading/Idle (feature spec Testing Decisions) — not
/// unit-testable, unlike `ActivityPhase.color` itself.
@MainActor
final class FloatingPanel: NSPanel {
    /// Tiles scroll rather than resize the panel: the panel's width/side are fixed for this
    /// feature (epic "Out of scope"), and a real machine can easily have more panes than fit
    /// in one screen height (verified manually against this dev machine's ~35 panes).
    private let scrollView = NSScrollView()

    /// One retained `TileCardView` per rendered Tile, keyed by `pane_id` (`TileState.id`) —
    /// lets `render(_:)` and the blink timer update an existing Tile's color/text in place
    /// instead of replacing `documentView`, which would reset the scroll position every call
    /// (see `render(_:)`'s doc comment).
    private var tileViewsByID: [String: TileCardView] = [:]
    /// The pane-id order last rendered. `topology.current` (`StatusBarEngine`) only changes on
    /// a `reconcile()` pass, so this stays equal to the incoming order on every phase-refresh
    /// and blink tick in between — `render(_:)` uses that to skip the rebuild path.
    private var renderedOrder: [String] = []
    /// The Tile list `render(_:)` last received, so the blink timer (which fires on its own
    /// cadence, not from a caller-supplied Tile list) knows which currently-rendered Tiles are
    /// in `.blinking` phase.
    private var currentTiles: [TileState] = []
    /// Toggled every `defaultBlinkPeriod / 2` seconds by `blinkTimer`; passed to every
    /// `TileCardView.apply(_:blinkOn:)` call, which is where a `.blinking` Tile's dot actually
    /// pulses in size (TASK-009: grows/shrinks between `TileCardView.dotMinSize` and
    /// `dotMaxSize`) — color stays fixed at `ActivityPhase.color` throughout.
    private var blinkOn = true
    /// Drives the Blinking phase's on/off cycle (SPEC §1 `blinkPeriod`) at the App layer only —
    /// `ActivityPhase` stays a pure function of `idleDuration` (SPEC §1: "driven entirely by
    /// idleDuration"), with no notion of wall-clock blink state.
    private var blinkTimer: Timer?

    /// Panel corner radius (TASK-007) — applied to the backing `NSVisualEffectView`'s layer
    /// since the window itself is `.borderless` and has no native chrome to round.
    private static let cornerRadius: CGFloat = 14
    /// Static branding header geometry — see its construction in `init` for why it's a
    /// fixed-height row rather than an adaptive one (no live data to size around).
    private static let headerHeight: CGFloat = 36
    private static let headerPadding: CGFloat = 10
    private static let headerIconSize: CGFloat = 14
    private static let headerIconLabelSpacing: CGFloat = 6

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
        // The window itself is transparent (TASK-007): its rectangular backing store would
        // otherwise show square corners around the rounded `NSVisualEffectView` below.
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))

        // TASK-007: vibrant/frosted material replaces the old flat black fill, with rounded
        // corners so the panel reads as deliberate macOS chrome rather than a debug overlay.
        // Sits behind `scrollView`, which stays transparent (`drawsBackground = false`) so the
        // material shows through everywhere Tiles don't cover it.
        //
        // TASK-012: the hairline border TASK-007 originally added here is gone — user screenshot
        // feedback was that it read as a visible outer window frame around the whole panel, which
        // this task's acceptance criteria explicitly call out to remove. Rounded corners stay:
        // the acceptance item is "no outer frame/border," not "no corner radius."
        let material = NSVisualEffectView(frame: content.bounds)
        material.autoresizingMask = [.width, .height]
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = Self.cornerRadius
        material.layer?.masksToBounds = true
        content.addSubview(material)

        // Static branding header — purely decorative, no live data, never updates after
        // init. Echoes the Menu Bar Icon's own `rectangle.stack` glyph so the panel reads
        // as the same product at a glance. Sits on top of `material` (no background of
        // its own), pinned to the content's top edge via `.minYMargin` so it stays put
        // if the panel is ever resized (e.g. a screen change while hidden).
        let header = NSView(frame: NSRect(x: 0, y: content.bounds.height - Self.headerHeight, width: content.bounds.width, height: Self.headerHeight))
        header.autoresizingMask = [.width, .minYMargin]
        content.addSubview(header)

        // Vivid cool-toned wash under the header content — indigo -> violet, high enough
        // alpha to read as a deliberate colored band (not a translucent hint like
        // `TileCardView.tintLayer`'s phase tint). Clipped to the panel's own top corners
        // so it never shows square corners poking out above `material`'s rounded rect.
        let headerTint = NSView(frame: header.bounds)
        headerTint.autoresizingMask = [.width, .height]
        headerTint.wantsLayer = true
        let gradient = CAGradientLayer()
        gradient.frame = header.bounds
        // "Slate" — chosen from a set of green/blue/grey candidates previewed for the
        // user (2026-08-14); rejects the earlier indigo/violet gradient outright.
        gradient.colors = [
            NSColor(red: 0.322, green: 0.361, blue: 0.431, alpha: 0.95).cgColor,
            NSColor(red: 0.200, green: 0.227, blue: 0.282, alpha: 0.90).cgColor
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        headerTint.layer?.addSublayer(gradient)
        headerTint.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        headerTint.layer?.cornerRadius = Self.cornerRadius
        headerTint.layer?.masksToBounds = true
        header.addSubview(headerTint)

        let headerIcon = NSImageView(frame: NSRect(x: Self.headerPadding, y: (Self.headerHeight - Self.headerIconSize) / 2, width: Self.headerIconSize, height: Self.headerIconSize))
        headerIcon.autoresizingMask = [.maxXMargin]
        let iconImage = NSImage(systemSymbolName: "rectangle.stack.fill", accessibilityDescription: nil)
        iconImage?.isTemplate = true
        headerIcon.image = iconImage
        headerIcon.contentTintColor = .white
        header.addSubview(headerIcon)

        let headerLabel = NSTextField(labelWithString: "MY AGENTS")
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .white
        let labelHeight = headerLabel.intrinsicContentSize.height
        headerLabel.frame = NSRect(
            x: Self.headerPadding + Self.headerIconSize + Self.headerIconLabelSpacing,
            y: (Self.headerHeight - labelHeight) / 2,
            width: content.bounds.width - Self.headerPadding * 2 - Self.headerIconSize - Self.headerIconLabelSpacing,
            height: labelHeight
        )
        headerLabel.autoresizingMask = [.width]
        header.addSubview(headerLabel)

        // Hairline divider separating the header from the scrollable Tile list below it
        // — same 12%-white treatment `TileCardView`'s own card border already uses.
        let divider = NSView(frame: NSRect(x: 0, y: 0, width: content.bounds.width, height: 1))
        divider.autoresizingMask = [.width]
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        header.addSubview(divider)

        scrollView.frame = NSRect(x: 0, y: 0, width: content.bounds.width, height: content.bounds.height - Self.headerHeight)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        content.addSubview(scrollView)
        contentView = content

        blinkTimer = Timer.scheduledTimer(withTimeInterval: TmuxCore.defaultBlinkPeriod / 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.toggleBlink() }
        }
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

    /// Renders `tiles`. When the pane set/order is unchanged from the last render (true for
    /// every phase-refresh and blink tick between `reconcile()` passes — `StatusBarEngine`'s
    /// `topology` only changes on a discovery pass), updates each existing Tile view's color
    /// and text in place and leaves `documentView` untouched, preserving scroll position.
    /// Rebuilds from scratch only when panes were added, removed, or reordered.
    func render(_ tiles: [TileState]) {
        currentTiles = tiles
        let ids = tiles.map(\.id)
        if ids == renderedOrder {
            for tile in tiles {
                tileViewsByID[tile.id]?.apply(tile, blinkOn: blinkOn)
            }
            return
        }

        let width = scrollView.contentSize.width
        let idealCardSize = TileCardView.cardSize
        // `contentSize.width` already reflects whatever the vertical scroller actually costs
        // right now (15pt under `.legacy`, ~0 under `.overlay` — see `TileCardView.cardSize`'s
        // doc comment). Clamping the card to what's left, rather than assuming the ideal 100pt
        // always fits, is what keeps the Activity Phase dot (centered on the header row via
        // `dotCenter`) from being clipped by the clip view under legacy scrollers.
        // Widened 4 -> 8pt on direct user feedback (2026-08-14, comparing against the
        // header-color-picker mockup's proportions), paired with `frame(on:)`'s matching
        // width bump so the ideal 120pt card width is unaffected — only the frame's own
        // breathing room around it grows.
        let horizontalMargin: CGFloat = 8
        let cardWidth = min(idealCardSize.width, max(width - horizontalMargin * 2, 0))
        let spacing: CGFloat = 6
        let contentHeight = max(
            CGFloat(tiles.count) * (idealCardSize.height + spacing) + spacing,
            scrollView.contentSize.height
        )
        let document = NSView(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))

        var newViews: [String: TileCardView] = [:]
        var y = contentHeight - spacing - idealCardSize.height
        let x = max((width - cardWidth) / 2, 0)
        for tile in tiles {
            let card = TileCardView(width: cardWidth)
            card.view.frame.origin = NSPoint(x: x, y: y)
            document.addSubview(card.view)
            card.apply(tile, blinkOn: blinkOn)
            newViews[tile.id] = card
            y -= (idealCardSize.height + spacing)
        }
        scrollView.documentView = document
        tileViewsByID = newViews
        renderedOrder = ids
    }

    /// Toggles the blink phase and reapplies color to every currently-rendered Tile in
    /// `.blinking` phase — the App-layer half of SPEC §1's `blinkPeriod`. Fires on its own
    /// timer, independent of `render(_:)`'s callers, so it re-reads `currentTiles` rather than
    /// taking a Tile list as a parameter.
    private func toggleBlink() {
        blinkOn.toggle()
        for tile in currentTiles {
            guard case .blinking = tile.phase else { continue }
            tileViewsByID[tile.id]?.apply(tile, blinkOn: blinkOn)
        }
    }

    private static func frame(on screen: NSScreen?) -> NSRect {
        // TASK-007: widened from 60pt to give tiles more room (TASK-008 follow-on).
        // TASK-012: widened again 92 -> 110pt so `TileCardView.cardSize.width` could grow past
        // its old 84pt ceiling (92pt was exactly `84 + 2*4`, the max the old card width could
        // reach under `render(_:)`'s overlay-scroller margin — there was no slack left to widen
        // the card without widening the panel too). Widened again 110 -> 130pt on direct user
        // feedback, same reasoning. Widened again 130 -> 138pt (2026-08-14) purely to match
        // `render(_:)`'s `horizontalMargin` bump (4 -> 8pt) one-for-one — this leaves
        // `TileCardView.cardSize.width` (120pt, unchanged) exactly as much room as before;
        // only the frame's own breathing room around the Tiles grows. Still respects the
        // legacy-scroller clamp: see `TileCardView.cardSize`'s doc comment for the
        // 130 -> 107pt-under-`.legacy` math (unaffected by this change, same margin delta).
        let width: CGFloat = 138
        guard let visible = screen?.visibleFrame else {
            return NSRect(x: 0, y: 0, width: width, height: 400)
        }
        return NSRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height)
    }
}
