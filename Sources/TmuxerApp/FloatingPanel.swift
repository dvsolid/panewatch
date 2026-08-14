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
    /// alternates color (`TileCardView.blinkOffColor`).
    private var blinkOn = true
    /// Drives the Blinking phase's on/off cycle (SPEC §1 `blinkPeriod`) at the App layer only —
    /// `ActivityPhase` stays a pure function of `idleDuration` (SPEC §1: "driven entirely by
    /// idleDuration"), with no notion of wall-clock blink state.
    private var blinkTimer: Timer?

    /// Panel corner radius (TASK-007) — applied to the backing `NSVisualEffectView`'s layer
    /// since the window itself is `.borderless` and has no native chrome to round.
    private static let cornerRadius: CGFloat = 14

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
        // corners and a subtle hairline border so the panel reads as deliberate macOS chrome
        // rather than a debug overlay. Sits behind `scrollView`, which stays transparent
        // (`drawsBackground = false`) so the material shows through everywhere Tiles don't
        // cover it.
        let material = NSVisualEffectView(frame: content.bounds)
        material.autoresizingMask = [.width, .height]
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = Self.cornerRadius
        material.layer?.masksToBounds = true
        material.layer?.borderWidth = 1
        material.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        content.addSubview(material)

        scrollView.frame = content.bounds
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
        let cardSize = TileCardView.cardSize
        let spacing: CGFloat = 6
        let contentHeight = max(
            CGFloat(tiles.count) * (cardSize.height + spacing) + spacing,
            scrollView.contentSize.height
        )
        let document = NSView(frame: NSRect(x: 0, y: 0, width: width, height: contentHeight))

        var newViews: [String: TileCardView] = [:]
        var y = contentHeight - spacing - cardSize.height
        let x = max((width - cardSize.width) / 2, 0)
        for tile in tiles {
            let card = TileCardView()
            card.view.frame.origin = NSPoint(x: x, y: y)
            document.addSubview(card.view)
            card.apply(tile, blinkOn: blinkOn)
            newViews[tile.id] = card
            y -= (cardSize.height + spacing)
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
        let width: CGFloat = 92
        guard let visible = screen?.visibleFrame else {
            return NSRect(x: 0, y: 0, width: width, height: 400)
        }
        return NSRect(x: visible.maxX - width, y: visible.minY, width: width, height: visible.height)
    }
}
