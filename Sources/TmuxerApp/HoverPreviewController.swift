import AppKit
import TmuxCore

/// Owns the Hover Preview Popup's whole lifecycle (feature spec § Architecture) — hover
/// detection on each Tile, the popup's positioning (`HoverPopupPlacement`, `TmuxCore`) and
/// show/hide mechanics, and enforcing "only one popup live at a time." AppKit-facing and not
/// unit-testable, same discipline `FloatingPanel` already documents for its own live-cycling
/// behavior (feature spec Testing decisions).
///
/// TASK-014 covers show/hide/position only — the popup's body is a placeholder. TASK-015 fills
/// it with a live read-only SwiftTerm view of the hovered pane; TASK-020's Switch wiring is a
/// separate concern (double-click on the Tile itself, not this popup).
///
/// Subclasses `NSResponder` so `mouseEntered(with:)`/`mouseExited(with:)` are the SDK's own
/// already-selector-mapped overrides (`NSTrackingArea` dispatches directly to whatever `owner`
/// was given at construction) rather than a hand-rolled `@objc` selector. This instance is the
/// tracking-area owner for the popup's own content view directly; each Tile instead gets a
/// dedicated `TileHoverProxy` owner (see below). `NSTrackingArea.owner` is declared `weak` in the
/// AppKit SDK header — it does not retain — so this controller must hold each proxy strongly
/// itself (`proxies`, below) for as long as its Tile view is live, or the proxy is deallocated
/// the instant `attachHoverTracking` returns and no hover event ever reaches it.
@MainActor
final class HoverPreviewController: NSResponder {
    /// Feature spec: dwell before the popup opens (TASK-014 acceptance item 1).
    private static let dwellDelay: TimeInterval = 0.35
    /// Feature spec: grace period after leaving both the Tile and the popup before it closes
    /// (TASK-014 acceptance item 2).
    private static let closeGraceDelay: TimeInterval = 0.25

    /// Created lazily on first open, then reused for every subsequent Tile — repositioned and
    /// re-shown rather than recreated. `previewClient`, not this window object, is what's torn
    /// down/respawned per pane (see `close()`/`open(paneID:tileView:)`).
    private var popup: HoverPreviewPopup?
    /// The Preview Client (glossary) backing whichever popup is currently open — a fresh
    /// instance per `open(paneID:tileView:)` call, never reused across panes, so a new hover
    /// never shows the previous pane's stale scrollback while its own attach is still spinning
    /// up. `nil` whenever no popup is open. Held strongly for the same reason `proxies` is
    /// (below): `PreviewClient` wires itself as `terminalView.processDelegate`, which SwiftTerm
    /// declares `weak` — an unretained `PreviewClient` would deallocate immediately and
    /// acceptance items 4/5 (pane/window closed, spawn failed) would silently never fire.
    private var previewClient: PreviewClient?
    /// The pane whose popup is currently shown on screen. `nil` when no popup is open.
    private var activePaneID: String?
    /// The pane a dwell timer is currently counting down for — distinct from `activePaneID`
    /// since the popup isn't open yet during the dwell.
    private var pendingPaneID: String?
    private var dwellTimer: Timer?
    private var closeTimer: Timer?
    /// Strong storage for every live Tile's `TileHoverProxy`, keyed by pane id.
    /// `NSTrackingArea.owner` is `weak` (not retained by the SDK), so without this dict each
    /// proxy would be deallocated the instant `attachHoverTracking` returns — `mouseEntered`/
    /// `mouseExited` would never reach a live owner and no popup would ever open. Pruned in
    /// `tileSetWillChange(remaining:)` so proxies for panes leaving the set are released rather
    /// than accumulating; overwritten on every `attachHoverTracking` call for a surviving pane,
    /// since `FloatingPanel.render(_:)`'s rebuild path always hands in a fresh `TileCardView`.
    private var proxies: [String: TileHoverProxy] = [:]

    /// Wires hover tracking onto one Tile's view. `FloatingPanel.render(_:)` calls this for
    /// every freshly created `TileCardView` on its rebuild path — that path always makes new
    /// views, so there's no explicit detach step for the view/tracking-area side: the old
    /// tracking areas go away with the old views they're attached to. The proxy itself is kept
    /// alive via `proxies` (see above) until this pane is pruned or superseded.
    func attachHoverTracking(to tileView: NSView, paneID: String) {
        let proxy = TileHoverProxy(paneID: paneID, tileView: tileView, controller: self)
        tileView.addTrackingArea(Self.hoverTrackingArea(owner: proxy))
        proxies[paneID] = proxy
        assert(
            tileView.trackingAreas.contains { $0.owner != nil },
            "TileHoverProxy for \(paneID) was deallocated — hover events will never reach it"
        )
    }

    /// Called by `FloatingPanel.render(_:)` right before it rebuilds the Tile list for a new
    /// pane set. If the pane the popup is open for (or mid-dwell for) is about to disappear,
    /// tears down that state now — otherwise the popup would be left positioned against (or
    /// about to open against) a Tile view that's about to be deallocated. Also prunes `proxies`
    /// for every pane leaving the set, since nothing else releases them (see `proxies`' doc
    /// comment).
    func tileSetWillChange(remaining paneIDs: Set<String>) {
        if let active = activePaneID, !paneIDs.contains(active) {
            close()
        }
        if let pending = pendingPaneID, !paneIDs.contains(pending) {
            cancelDwell()
        }
        proxies = proxies.filter { paneIDs.contains($0.key) }
    }

    fileprivate func tileMouseEntered(paneID: String, tileView: NSView) {
        cancelDwell()

        if let active = activePaneID {
            if active == paneID {
                // Re-entering the Tile whose popup is already open — cancel any pending close,
                // no new dwell needed.
                cancelClose()
                return
            }
            // Hovering a second Tile while a popup is already open: close the first before
            // scheduling the new one (acceptance item 3 — only one popup live at a time).
            close()
        }

        pendingPaneID = paneID
        let timer = Timer(timeInterval: Self.dwellDelay, repeats: false) { [weak self, weak tileView] _ in
            Task { @MainActor in
                guard let self, let tileView else { return }
                self.open(paneID: paneID, tileView: tileView)
            }
        }
        // `.common` rather than the default `.default` run loop mode: `NSScrollView`'s own
        // tracking loop while the Tile list is being scrolled runs in `.eventTracking`, which
        // would otherwise starve this timer indefinitely if a hover starts mid-scroll-gesture.
        RunLoop.main.add(timer, forMode: .common)
        dwellTimer = timer
    }

    fileprivate func tileMouseExited(paneID: String) {
        if pendingPaneID == paneID {
            // Left the Tile before its dwell delay elapsed — the popup never opened.
            cancelDwell()
        }
        if activePaneID == paneID {
            scheduleClose()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        // Only the popup's own content view uses `self` as tracking-area owner directly (Tiles
        // route through `TileHoverProxy`) — entering the popup cancels any pending close from
        // having just left the Tile (acceptance item 2: "moving from the Tile directly into the
        // popup does not close it").
        cancelClose()
    }

    override func mouseExited(with event: NSEvent) {
        guard activePaneID != nil else { return }
        scheduleClose()
    }

    private func open(paneID: String, tileView: NSView) {
        dwellTimer = nil
        pendingPaneID = nil
        // A card can in principle exist before it's attached into the view hierarchy; skip
        // rather than crash if there's no window/screen to position against yet.
        guard let window = tileView.window, let screen = window.screen ?? NSScreen.main else { return }

        let tileFrameOnScreen = window.convertToScreen(tileView.convert(tileView.bounds, to: nil))
        let frame = HoverPopupPlacement.frame(forTile: tileFrameOnScreen, within: screen.visibleFrame)

        let panel = popup ?? makePopup()
        popup = panel
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        activePaneID = paneID

        startPreview(paneID: paneID, popup: panel)
    }

    /// Creates this open's `PreviewClient`, embeds its terminal view into the popup, and
    /// starts the attach. `open(paneID:tileView:)` only ever calls this when `previewClient`
    /// is already `nil` — either the very first open, or after `close()` has torn down
    /// whatever was there before (`tileMouseEntered`'s second-Tile-hover path always calls
    /// `close()` before starting a new dwell) — so there's no old client to stop here first.
    private func startPreview(paneID: String, popup: HoverPreviewPopup) {
        let client = PreviewClient()
        previewClient = client
        client.onOutcome = { [weak self] outcome in
            switch outcome {
            case .unavailable:
                // The spawn itself failed (acceptance item 5) — leave the popup open, showing
                // the inline unavailable state, rather than closing it out from under the user.
                self?.popup?.showUnavailable()
            case .closed:
                // The pane/window closed underneath an already-live preview (acceptance item
                // 4) — `close()` is idempotent and also tears this client down.
                self?.close()
            }
        }
        popup.showTerminal(client.terminalView)
        client.start(paneID: paneID)
    }

    /// Idempotent. Also tears down the active Preview Client (if any) — terminates its
    /// process and its grouped tmux session, so `tmux list-clients` no longer lists it once
    /// this returns (acceptance item 2).
    private func close() {
        cancelDwell()
        cancelClose()
        activePaneID = nil
        popup?.orderOut(nil)
        previewClient?.stop()
        previewClient = nil
    }

    private func cancelDwell() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        pendingPaneID = nil
    }

    private func cancelClose() {
        closeTimer?.invalidate()
        closeTimer = nil
    }

    private func scheduleClose() {
        closeTimer?.invalidate()
        let timer = Timer(timeInterval: Self.closeGraceDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
        RunLoop.main.add(timer, forMode: .common)
        closeTimer = timer
    }

    private func makePopup() -> HoverPreviewPopup {
        let panel = HoverPreviewPopup()
        if let content = panel.contentView {
            content.addTrackingArea(Self.hoverTrackingArea(owner: self))
        }
        return panel
    }

    /// Both the popup's content view and every `TileHoverProxy`-owned Tile view use the same
    /// tracking options — only the owner differs (Tiles route through their proxy; the popup uses
    /// this controller directly). `.inVisibleRect` means `rect: .zero` always tracks the owning
    /// view's actual bounds, growing/shrinking with it automatically.
    private static func hoverTrackingArea(owner: NSResponder) -> NSTrackingArea {
        NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: owner,
            userInfo: nil
        )
    }
}

/// One tracking-area owner per Tile, forwarding mouse-entered/exited to `HoverPreviewController`
/// along with the pane id and the Tile's own view (needed to compute its on-screen frame when
/// the popup opens). Kept alive by `HoverPreviewController.proxies` (strong, keyed by pane id) —
/// `NSTrackingArea.owner` itself is `weak` and does not retain, which is the opposite risk from a
/// retain cycle: without that dict this proxy would be deallocated the moment
/// `attachHoverTracking` returns.
///
/// `tileView` is still held weakly, not strongly, but for a different reason: the controller
/// retains this proxy across `FloatingPanel.render(_:)` rebuilds (until the pane is pruned or
/// superseded), and `render(_:)` recreates `TileCardView`s wholesale on every pane-set change —
/// a strong `tileView` here would keep discarded card views alive past their rebuild. `controller`
/// is likewise weak: the controller now owns this proxy strongly, so a strong back-reference
/// would be a genuine retain cycle (controller -> proxy -> controller).
@MainActor
private final class TileHoverProxy: NSResponder {
    private let paneID: String
    private weak var controller: HoverPreviewController?
    private weak var tileView: NSView?

    init(paneID: String, tileView: NSView, controller: HoverPreviewController) {
        self.paneID = paneID
        self.tileView = tileView
        self.controller = controller
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("TileHoverProxy does not support NSCoding")
    }

    override func mouseEntered(with event: NSEvent) {
        guard let tileView else { return }
        controller?.tileMouseEntered(paneID: paneID, tileView: tileView)
    }

    override func mouseExited(with event: NSEvent) {
        controller?.tileMouseExited(paneID: paneID)
    }
}

/// The Hover Preview Popup window itself — a small non-activating panel, sized per the feature
/// spec's fixed ~420x260pt (TASK-014 acceptance item 4, not resizable: `.borderless` with no
/// `.resizable` style bit, and nothing in `HoverPreviewController` ever changes its size). Body
/// is either a live `PreviewClient.terminalView` (`showTerminal(_:)`) or an inline "preview
/// unavailable" state (`showUnavailable()`, acceptance item 5) — `HoverPreviewController` swaps
/// between them per `PreviewClient.Outcome`.
///
/// Mirrors `FloatingPanel`'s own posture for a window that must never steal focus: explicit
/// `canBecomeKey`/`canBecomeMain` overrides on top of `.nonactivatingPanel`'s own default (see
/// `FloatingPanel`'s doc comment for why the style mask alone isn't enough), `hidesOnDeactivate
/// = false`, and a `collectionBehavior` that keeps it floating above all Spaces/full-screen apps
/// the same way `FloatingPanel` does. This is also one half of TASK-015's read-only preview
/// guarantee being structural rather than a promise: a window that can never become key can
/// never receive keystrokes to forward in the first place (the other half is
/// `ReadOnlyLocalProcessTerminalView.send`, `PreviewClient.swift`).
@MainActor
private final class HoverPreviewPopup: NSPanel {
    private static let cornerRadius: CGFloat = 12
    /// Keeps the terminal/unavailable content off the card's rounded corners.
    private static let contentInset: CGFloat = 10

    /// Holds whichever of `showTerminal(_:)`/`showUnavailable()` is currently displayed, so
    /// swapping between them is just "remove this container's subviews, add the new one" —
    /// never touches `material` (the background) or the window's own content view.
    private let innerContent: NSView
    private let unavailableLabel: NSTextField

    init() {
        let size = HoverPopupPlacement.size
        let innerContent = NSView(frame: NSRect(
            x: Self.contentInset,
            y: Self.contentInset,
            width: size.width - Self.contentInset * 2,
            height: size.height - Self.contentInset * 2
        ))
        innerContent.autoresizingMask = [.width, .height]
        self.innerContent = innerContent

        let unavailableLabel = NSTextField(labelWithString: "Preview unavailable")
        unavailableLabel.font = .systemFont(ofSize: 12, weight: .medium)
        unavailableLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        unavailableLabel.alignment = .center
        self.unavailableLabel = unavailableLabel

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Reused across opens (`HoverPreviewController.popup`) rather than recreated per Tile —
        // without this, `orderOut(nil)` on close would let AppKit release the window and the
        // next `open(paneID:tileView:)` would be handed a dangling reference.
        isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true

        let material = NSVisualEffectView(frame: content.bounds)
        material.autoresizingMask = [.width, .height]
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = Self.cornerRadius
        material.layer?.masksToBounds = true
        content.addSubview(material)

        content.addSubview(innerContent)

        unavailableLabel.frame = innerContent.bounds
        unavailableLabel.autoresizingMask = [.width, .height]
        unavailableLabel.isHidden = true
        innerContent.addSubview(unavailableLabel)

        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Displays a live terminal view (`PreviewClient.terminalView`), replacing whatever this
    /// popup was showing before — a fresh `PreviewClient` per `open(paneID:tileView:)` means a
    /// fresh view here too, so the previous pane's frame never lingers on screen while the new
    /// attach is still spinning up.
    func showTerminal(_ view: NSView) {
        unavailableLabel.isHidden = true
        clearTerminalViews()
        view.frame = innerContent.bounds
        view.autoresizingMask = [.width, .height]
        innerContent.addSubview(view)
    }

    /// Acceptance item 5: the spawn failed outright — show the inline state instead of
    /// whatever `showTerminal(_:)` last displayed (a blank/frozen terminal view).
    func showUnavailable() {
        clearTerminalViews()
        unavailableLabel.isHidden = false
    }

    private func clearTerminalViews() {
        for subview in innerContent.subviews where subview !== unavailableLabel {
            subview.removeFromSuperview()
        }
    }
}
