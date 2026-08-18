import AppKit
import Foundation
import TmuxCore

// swiftlint:disable file_length
// Pre-existing size debt, not a lint-setup-time refactor: tracked for a future split, not a
// green light for new files to grow this large.

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
// swiftlint:disable:next type_body_length
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
    /// TASK-034: the two signals `HoverPreviewCloseGate.shouldStayOpen(_:)` decides on. Both
    /// reset to `false` whenever the popup fully closes (`closeAndDetachClient()`,
    /// `tearDownActivePreviewSynchronously()`) so stale state from one pane's hover never
    /// leaks into the next — this same popup/panel instance is reused across every hover.
    /// `mouseInsideActiveArea` covers the union of "mouse is over the active Tile" and "mouse
    /// is over the popup itself" — the two areas every close-timer call site already treated
    /// identically before this task (`tileMouseEntered`/`Exited`, `mouseEntered`/`Exited`
    /// below), so one flag suffices for both.
    private var mouseInsideActiveArea = false
    private var fieldFocused = false
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

    /// TASK-020's Switch wiring: every `TmuxCore` module the double-click path resolves
    /// through, in order — `paneDiscovery`/`clientDiscovery` share `gateway` with the
    /// resolvers below purely for construction convenience (each `scan()` is a fresh
    /// process spawn regardless). All `Sendable`, so `tileDoubleClicked(paneID:)` can hand
    /// them straight to `Task.detached` without hopping back through `self`.
    private let gateway: any TmuxGateway
    private let tmuxPath: String
    private let paneDiscovery: PaneDiscovery
    private let clientDiscovery: ClientDiscovery
    private let ttyOwnerResolver: any TTYOwnerResolver
    private let switchPlanner: SwitchActionPlanner
    private let scriptRunner: any AppleScriptRunner
    /// Forwarded to every `PreviewClient` this controller creates (`startPreview`), so its
    /// `PreviewClientLifecycle` can mute the previewed pane's own zoom-induced repaint out of
    /// activity tracking — see `ActivityStateStore.muteOutput(paneId:until:)`'s doc comment.
    /// `nil` by default (matches every other collaborator's headless-testable default here):
    /// a controller built without one just never mutes, same as before this existed.
    private let activityMuter: (any ActivityMuter)?

    init(
        gateway: any TmuxGateway = ProcessTmuxGateway(),
        tmuxPath: String = TmuxCore.defaultTmuxPath,
        ttyOwnerResolver: any TTYOwnerResolver = ProcessTableTTYOwnerResolver(),
        switchPlanner: SwitchActionPlanner = SwitchActionPlanner(),
        scriptRunner: any AppleScriptRunner = OSAScriptRunner(),
        activityMuter: (any ActivityMuter)? = nil
    ) {
        self.gateway = gateway
        self.tmuxPath = tmuxPath
        self.paneDiscovery = PaneDiscovery(gateway: gateway)
        self.clientDiscovery = ClientDiscovery(gateway: gateway)
        self.ttyOwnerResolver = ttyOwnerResolver
        self.switchPlanner = switchPlanner
        self.scriptRunner = scriptRunner
        self.activityMuter = activityMuter
        super.init()
    }

    required init?(coder: NSCoder) {
        fatalError("HoverPreviewController does not support NSCoding")
    }

    /// Wires hover tracking, plus TASK-020's double-click-to-Switch gesture, onto one Tile's
    /// view. `FloatingPanel.render(_:)` calls this for every freshly created `TileCardView` on
    /// its rebuild path — that path always makes new views, so there's no explicit detach step
    /// for the view/tracking-area/gesture-recognizer side: the old ones go away with the old
    /// views they're attached to. The proxy itself is kept alive via `proxies` (see above)
    /// until this pane is pruned or superseded.
    ///
    /// `numberOfClicksRequired = 2` makes a single click structurally inert (acceptance item
    /// 4) — there is no single-click recognizer or `mouseDown` override anywhere on this view
    /// to fire on the first click alone; the gesture simply never resolves until the second one
    /// lands.
    func attachHoverTracking(to tileView: NSView, paneID: String) {
        let proxy = TileHoverProxy(paneID: paneID, tileView: tileView, controller: self)
        tileView.addTrackingArea(Self.hoverTrackingArea(owner: proxy))

        let doubleClick = NSClickGestureRecognizer(target: proxy, action: #selector(TileHoverProxy.handleDoubleClick))
        doubleClick.numberOfClicksRequired = 2
        tileView.addGestureRecognizer(doubleClick)

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
                mouseInsideActiveArea = true
                updateCloseState()
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
            mouseInsideActiveArea = false
            updateCloseState()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        // Only the popup's own content view uses `self` as tracking-area owner directly (Tiles
        // route through `TileHoverProxy`) — entering the popup cancels any pending close from
        // having just left the Tile (acceptance item 2: "moving from the Tile directly into the
        // popup does not close it").
        mouseInsideActiveArea = true
        updateCloseState()
    }

    override func mouseExited(with event: NSEvent) {
        guard activePaneID != nil else { return }
        mouseInsideActiveArea = false
        updateCloseState()
    }

    /// TASK-034: the single place every mouse-tracking/field-focus call site above routes
    /// through, rather than calling `scheduleClose()`/`cancelClose()` directly — consults
    /// `HoverPreviewCloseGate.shouldStayOpen(_:)` on the current `mouseInsideActiveArea`/
    /// `fieldFocused` pair and only then decides which of the two to invoke. A no-op while no
    /// popup is open (`activePaneID == nil`): none of the mouse/focus events above have
    /// anything to schedule or cancel yet.
    private func updateCloseState() {
        guard activePaneID != nil else { return }
        let signal = HoverPreviewCloseGate.Signal(mouseInside: mouseInsideActiveArea, fieldFocused: fieldFocused)
        if HoverPreviewCloseGate.shouldStayOpen(signal) {
            cancelClose()
        } else {
            scheduleClose()
        }
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
        // The dwell timer that led here only ever fires while the mouse is still over the
        // Tile (`tileMouseExited` cancels it otherwise) — seed `mouseInsideActiveArea`
        // accordingly rather than leaving it at its stale `false` default, which would
        // schedule a spurious close on the very first `updateCloseState()` call.
        mouseInsideActiveArea = true
        fieldFocused = false

        startPreview(paneID: paneID, popup: panel)
    }

    /// Creates this open's `PreviewClient`, embeds its terminal view into the popup, and
    /// starts the attach. `open(paneID:tileView:)` only ever calls this when `previewClient`
    /// is already `nil` — either the very first open, or after `close()` has torn down
    /// whatever was there before (`tileMouseEntered`'s second-Tile-hover path always calls
    /// `close()` before starting a new dwell) — so there's no old client to stop here first.
    private func startPreview(paneID: String, popup: HoverPreviewPopup) {
        let client = PreviewClient(activityMuter: activityMuter)
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

    /// Idempotent. Also detaches the active Preview Client (if any) and fires its grouped-tmux-
    /// session teardown in a detached task — the ordinary close path, used by every caller
    /// that doesn't need the teardown to *complete* before some other tmux call runs
    /// (`tileMouseEntered`'s second-Tile-hover path, `scheduleClose`, `tileSetWillChange`, the
    /// `.closed` outcome). `tileDoubleClicked` needs that stronger guarantee and calls
    /// `closeAndDetachClient()` directly instead — see its own doc comment.
    private func close() {
        let teardown = closeAndDetachClient()
        Task.detached { teardown() }
    }

    /// The state-teardown half of `close()`, factored out so `tileDoubleClicked` can await the
    /// returned closure itself instead of racing it against a separately-dispatched
    /// `Task.detached` (whole-branch review finding: firing both independently broke the
    /// "teardown completes before the switch resolve begins" guarantee this method's callers
    /// depend on). Cancels timers, hides the popup, clears `activePaneID`, and detaches
    /// `previewClient`'s UI/process — all cheap main-actor work. The returned closure is the
    /// one blocking piece (`PreviewClientLifecycle.teardownGroupSession`'s `kill-session`
    /// spawn, via `PreviewClient.stop()`), left for the caller to run wherever is appropriate.
    @discardableResult
    private func closeAndDetachClient() -> @Sendable () -> Void {
        cancelDwell()
        cancelClose()
        activePaneID = nil
        mouseInsideActiveArea = false
        fieldFocused = false
        popup?.orderOut(nil)
        let teardown: @Sendable () -> Void
        if let previewClient {
            teardown = previewClient.stop()
        } else {
            teardown = {}
        }
        previewClient = nil
        return teardown
    }

    /// `FloatingPanel.toggleVisibility()` hides the main panel with no idea whether a hover
    /// popup is currently open — call this from there so a popup left open when the user hides
    /// the panel doesn't leak its grouped tmux session indefinitely (whole-branch review
    /// finding: hiding the panel never runs `tileSetWillChange`, so nothing else would ever
    /// close it). Ordinary fire-and-forget close, same as every non-`tileDoubleClicked` caller.
    func closeActivePreview() {
        close()
    }

    /// Synchronous teardown for `AppDelegate.applicationWillTerminate` (whole-branch review
    /// finding: without this, quitting the app with a popup open — or crashing — leaves its
    /// `panewatch-preview-*` session on the tmux server indefinitely, since neither a detached
    /// task nor the next-hover best-effort cleanup ever gets a chance to run). See
    /// `PreviewClient.stopSynchronously()` for why this can't reuse the async `close()` path.
    func tearDownActivePreviewSynchronously() {
        cancelDwell()
        cancelClose()
        activePaneID = nil
        mouseInsideActiveArea = false
        fieldFocused = false
        popup?.orderOut(nil)
        previewClient?.stopSynchronously()
        previewClient = nil
    }

    /// TASK-032: Preview Input's Send/Enter wiring, called by `HoverPreviewPopup
    /// .onSubmitInlineReply` for whichever pane is currently active. Empty/whitespace-only
    /// `text` is a no-op (acceptance item 5) — trimmed and checked here, on the main actor,
    /// before `InlineReplyInvocation` is ever reached, so a blank submit never builds or sends
    /// an argument vector at all. The two `TmuxGateway.run(_:)` calls (conditional on the first
    /// succeeding — see `sendInlineReply` below) are blocking I/O and run off the main actor via
    /// `Task.detached`, the same discipline `tileDoubleClicked` uses — `sendInlineReply` below is
    /// `nonisolated static` and takes only `Sendable` values for the same reason `performSwitch`
    /// is. Never calls `close()`/`scheduleClose()`: the popup staying open and showing the same
    /// pane afterward (acceptance item 7) is simply this method never touching either.
    func performInlineReply(paneID: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let gateway = gateway
        let activityMuter = activityMuter
        Task.detached {
            Self.sendInlineReply(paneID: paneID, text: trimmed, gateway: gateway, activityMuter: activityMuter)
        }
    }

    /// ADR-0006's two-step write: the literal text, then a separate `Enter` — never combined,
    /// mirroring `InlineReplyInvocation`'s own split. The `Enter` call only runs when the
    /// literal-text send actually succeeded (whole-branch review finding: sending `Enter`
    /// unconditionally could deliver a bare `Enter` keystroke with no text if the first call
    /// failed, which `InlineReplyInvocation`'s own doc comment says must never happen). A pane
    /// that vanished between the popup opening and the user hitting Send still no-ops rather
    /// than throwing into the UI — `submitInlineReply()` on the popup side has already cleared
    /// the input field by the time this runs, so a failure is logged (`logInlineReplyFailure`,
    /// mirroring `logOpenNewFailure`'s posture below) rather than swallowed with no trace, even
    /// though there's no UI surface here to show it on. Not `private` — the whole-branch-review
    /// test for this fix calls it directly against a fake `TmuxGateway`, the same test seam
    /// `PreviewClientLifecycleTests` uses for `PreviewClientLifecycle`.
    ///
    /// `activityMuter?.forceRecordOutput` fires immediately after a successful literal-text
    /// send (bug fix: the Tile could take a while to show the reply as activity, or miss it
    /// entirely, when `PreviewClientLifecycle`'s own zoom mute — armed the moment this same
    /// popup opened — was still covering the pane; `recordOutput`'s normal path silently drops
    /// output landing inside that window, and the polled/control-mode sample carrying the
    /// reply's real activity has no way to tell itself apart from the mute's intended target,
    /// the zoom's self-inflicted repaint). Fired on send, not on the `Enter` outcome — the
    /// literal text is what makes the pane's foreground program do something, `Enter` is just
    /// how it's submitted.
    nonisolated static func sendInlineReply(
        paneID: String,
        text: String,
        gateway: any TmuxGateway,
        activityMuter: (any ActivityMuter)? = nil
    ) {
        do {
            _ = try gateway.run(InlineReplyInvocation.literalTextArguments(paneId: paneID, text: text))
        } catch {
            logInlineReplyFailure("literal-text send failed: \(error)")
            return
        }
        activityMuter?.forceRecordOutput(paneId: paneID, at: Date())
        do {
            _ = try gateway.run(InlineReplyInvocation.enterArguments(paneId: paneID))
        } catch {
            logInlineReplyFailure("Enter send failed: \(error)")
        }
    }

    /// Best-effort logging for a failed Preview Input reply (whole-branch review finding:
    /// previously swallowed with no trace at all, after the input field had already been
    /// cleared). Same floor as `logOpenNewFailure`: log it, no tooltip UI surfacing it to the
    /// user, out of scope for this fix pass.
    nonisolated private static func logInlineReplyFailure(_ message: String) {
        FileHandle.standardError.write(Data("panewatch: Preview Input reply failed: \(message)\n".utf8))
    }

    /// TASK-020: double-click-to-Switch, wired from every Tile's `TileHoverProxy` gesture
    /// recognizer (`attachHoverTracking`). Runs `closeAndDetachClient()` **unconditionally,
    /// first, and synchronously on the main actor** — before the `Task.detached` below even
    /// exists, let alone runs — regardless of whether this pane's popup is the one currently
    /// open (acceptance item 5: "always", not "if this Tile's own popup is open"; also needed
    /// for a pending dwell timer on some *other* Tile, which `closeAndDetachClient()`'s own
    /// `cancelDwell()` already covers).
    ///
    /// The blocking half of that teardown (the returned `teardown` closure —
    /// `PreviewClientLifecycle.teardownGroupSession`'s `kill-session` spawn, via
    /// `PreviewClient.stop()`) is deliberately *not* run inline on the main actor, nor fired
    /// into its own independent `Task.detached` the way `close()`'s other callers do — it's
    /// run first, awaited, inside the same detached task as `performSwitch`, below. That
    /// ordering isn't cosmetic (whole-branch review finding: two independently-scheduled
    /// detached tasks race, which silently breaks it): if any popup was open when the
    /// double-click landed, its `PreviewClient` is a real grouped tmux session and client that
    /// must be fully torn down before `performSwitch`'s own scans run. Left running during the
    /// resolve below, it poisons both scans this pass is about to do — verified live during
    /// TASK-015: a hovered pane's `pane_id` appears **twice** in `list-panes -a` while its
    /// grouped session is attached (once under the source session, once under the group), and
    /// the group's own tty shows up in `list-clients` with no owning app. Either would corrupt
    /// `resolveTarget`/`resolveAttachedClient` below in ways that only show up when a popup
    /// happened to be open first — i.e. the normal case, since double-clicking a Tile almost
    /// always follows hovering it.
    ///
    /// Everything past the main-actor teardown is blocking I/O (`kill-session`, `list-panes`,
    /// `list-clients`, `ps -A`, and — on the focus-existing path — `osascript`, which blocks on
    /// the OS's own Automation permission dialog the first time a given app is scripted) and
    /// must never run on the main actor, or the whole UI freezes behind it. `performSwitch` is
    /// a `nonisolated static` function taking only `Sendable` values precisely so
    /// `Task.detached` can run it without hopping back through `self` at all.
    fileprivate func tileDoubleClicked(paneID: String) {
        FileHandle.standardError.write(Data("panewatch: double-click received for \(paneID)\n".utf8))
        let teardown = closeAndDetachClient()

        let gateway = gateway
        let tmuxPath = tmuxPath
        let paneDiscovery = paneDiscovery
        let clientDiscovery = clientDiscovery
        let ttyOwnerResolver = ttyOwnerResolver
        let switchPlanner = switchPlanner
        let scriptRunner = scriptRunner
        let activityMuter = activityMuter

        Task.detached {
            teardown()
            Self.performSwitch(
                paneID: paneID,
                gateway: gateway,
                tmuxPath: tmuxPath,
                paneDiscovery: paneDiscovery,
                clientDiscovery: clientDiscovery,
                ttyOwnerResolver: ttyOwnerResolver,
                switchPlanner: switchPlanner,
                scriptRunner: scriptRunner,
                activityMuter: activityMuter
            )
        }
    }

    // swiftlint:disable function_parameter_count
    /// The full SPEC §4 priority-ladder pass for one double-click: resolve the pane's current
    /// `PaneTarget` and attached-client state fresh (never cached — the Tile list can be stale
    /// by the time a double-click lands), plan the outcome, then execute it. `nonisolated` and
    /// free of any reference to `self` so it's safe to run off the main actor from
    /// `tileDoubleClicked`'s `Task.detached`.
    nonisolated private static func performSwitch(
        paneID: String,
        gateway: any TmuxGateway,
        tmuxPath: String,
        paneDiscovery: PaneDiscovery,
        clientDiscovery: ClientDiscovery,
        ttyOwnerResolver: any TTYOwnerResolver,
        switchPlanner: SwitchActionPlanner,
        scriptRunner: any AppleScriptRunner,
        activityMuter: (any ActivityMuter)?
    ) {
        // swiftlint:enable function_parameter_count
        // The pane can have vanished between the double-click and this resolve (e.g. the agent
        // exited) — silently do nothing rather than act on stale/absent data, the same posture
        // `PreviewClientLifecycle.prepareGroupSession` takes for a dead pane.
        guard let (target, panes) = resolveTarget(paneID: paneID, paneDiscovery: paneDiscovery) else { return }
        let attachedClient = resolveAttachedClient(
            target: target,
            clientDiscovery: clientDiscovery,
            ttyOwnerResolver: ttyOwnerResolver
        )
        // TASK-036: every pane in the target's session is in the blast radius of the open-new
        // path's bare-pane-ID attach (root cause, this task's body) — computed once here, off
        // the one `PaneDiscovery.scan()` `resolveTarget` already ran, so neither
        // `performOpenNew` call site below re-scans (avoids a second scan / TOCTOU race).
        let matePaneIds = SwitchInvocation.sessionMatePaneIds(of: target, in: panes)

        let plan = switchPlanner.plan(target: target, attachedClient: attachedClient)
        FileHandle.standardError.write(Data("panewatch: switch plan for \(paneID) -> \(plan), attachedClient=\(String(describing: attachedClient))\n".utf8))
        switch plan {
        case .focusExisting(_, let script):
            // SPEC §4 step 1: retarget the tmux client already attached to this session
            // *before* the AppleScript runs — `SwitchActionPlanner`'s own doc comment is
            // explicit that this dispatch is the caller's job, not the planner's. Never
            // `attach` here (SPEC §4: "attach always creates an additional client").
            _ = try? gateway.run(SwitchInvocation.selectWindowArguments(target: target))
            _ = try? gateway.run(SwitchInvocation.selectPaneArguments(target: target))
            do {
                _ = try scriptRunner.run(script: script)
            } catch {
                // Acceptance item 3: Automation permission denied (or any other run failure)
                // falls back to opening a new terminal — always via Ghostty (`preferredApp:
                // nil`), never the app that just failed. **[REQ CHANGE], found live** (this
                // task's `## Implementation` notes, `task020-probe5`): preferring the failed
                // app here is silently ineffective for iTerm2/Terminal.app specifically,
                // because Automation permission is denied per (this process, that app) pair,
                // not per script — their own "open a new window" mechanism
                // (`SwitchInvocation.openNewAction`'s `.runScript` branch) is *also*
                // AppleScript, so it fails for the identical reason and nothing visibly
                // happens. Ghostty's open-new is a plain process launch with no
                // Automation-permission dependency at all — the only one of the three immune
                // to this exact failure mode, which is why it's the unconditional fallback
                // here even though the owning app is known. This still attaches by bare pane
                // ID (TASK-036 root cause), so it needs the same mute `performOpenNew` arms.
                performOpenNew(
                    preferredApp: nil,
                    tmuxPath: tmuxPath,
                    paneId: target.paneId,
                    scriptRunner: scriptRunner,
                    matePaneIds: matePaneIds,
                    activityMuter: activityMuter
                )
            }
        case .openNew(let paneId):
            performOpenNew(
                preferredApp: attachedClient?.owningApp,
                tmuxPath: tmuxPath,
                paneId: paneId,
                scriptRunner: scriptRunner,
                matePaneIds: matePaneIds,
                activityMuter: activityMuter
            )
        }
    }

    /// Finds the `RawPane` matching `paneID` in a fresh `PaneDiscovery.scan()` and builds its
    /// `PaneTarget` — this task's notes are explicit that this lookup gets no dedicated
    /// `TmuxCore` module of its own, just a filter over an existing scan at double-click time.
    /// Returns the full scanned pane list alongside the target (TASK-036) so callers needing
    /// session-mate context (`SwitchInvocation.sessionMatePaneIds`) don't have to re-scan.
    nonisolated private static func resolveTarget(paneID: String, paneDiscovery: PaneDiscovery) -> (target: PaneTarget, panes: [RawPane])? {
        guard let panes = try? paneDiscovery.scan(), let pane = panes.first(where: { $0.paneId == paneID }) else {
            return nil
        }
        let target = PaneTarget(paneId: pane.paneId, sessionName: pane.sessionName, windowIndex: pane.windowIndex, paneIndex: pane.paneIndex, currentPath: pane.currentPath)
        return (target, panes)
    }

    /// Matches a fresh `ClientDiscovery.scan()` by **session name**, not "the only client" or
    /// tty proximity — the session is the one thing `PaneTarget` and `ClientInfo` both carry,
    /// and matching on it is also what keeps this correct if `close()` above ever stops being
    /// perfectly synchronous with tmux's own state (belt-and-suspenders alongside the ordering
    /// documented on `tileDoubleClicked`).
    nonisolated private static func resolveAttachedClient(
        target: PaneTarget,
        clientDiscovery: ClientDiscovery,
        ttyOwnerResolver: any TTYOwnerResolver
    ) -> AttachedClient? {
        guard let clients = try? clientDiscovery.scan(), let client = clients.first(where: { $0.sessionName == target.sessionName }) else {
            return nil
        }
        return AttachedClient(tty: client.tty, owningApp: ttyOwnerResolver.resolveOwningApp(tty: client.tty))
    }

    /// Bundle identifier `resolveOpenNewPreferredApp` checks via `NSWorkspace` before letting
    /// `SwitchInvocation.openNewAction` default to Ghostty.
    nonisolated private static let ghosttyBundleID = "com.mitchellh.ghostty"

    // swiftlint:disable function_parameter_count
    /// SPEC §4 path 2, "open a new terminal attached to the pane" — dispatches
    /// `SwitchInvocation.openNewAction`'s two possible mechanisms. Best-effort past this point
    /// (the fallback of the fallback has nowhere further to go per this task's acceptance
    /// criteria — SPEC §4's own priority ladder ends at "open new," with only a tooltip
    /// fallback beyond it, out of scope here, see `SwitchAction`'s doc comment) but no longer
    /// silent: whole-branch review finding — `openNewAction` hardcoded Ghostty for both `.none`
    /// and `.ghostty`, and the old `try? process.run()` didn't even wait for `open` to exit, so
    /// "Unable to find application named 'Ghostty'" on a machine without it was invisible and
    /// both SPEC §4 path 2 and the Automation-denied fallback were silent no-ops. Now resolves
    /// through an availability check first and logs whichever mechanism still fails.
    nonisolated private static func performOpenNew(
        preferredApp: SupportedTerminalApp?,
        tmuxPath: String,
        paneId: String,
        scriptRunner: any AppleScriptRunner,
        matePaneIds: [String],
        activityMuter: (any ActivityMuter)?
    ) {
        // swiftlint:enable function_parameter_count
        // TASK-036 root cause: this function's attach mechanism (both branches below) is a
        // bare-pane-ID `tmux attach -t %<id>`, which makes the server replay every
        // Kitty-keyboard-protocol pane's mode-enable escape sequences to the newly-attaching
        // client as genuine `%output` activity — for every pane sharing this session, not only
        // `paneId`. Armed here, as the very first statement, before either branch's
        // process/AppleScript actually runs — mirrors `PreviewClientLifecycle
        // .prepareGroupSession`'s `muteActivity(paneID:)` ordering exactly (that type's own doc
        // comment: an earlier version muting at the end of the function left the *first* tmux
        // command's replay unmuted, live-verified as a real race, not a hypothetical one). Both
        // of this function's callers attach by bare pane ID (the `.openNew` plan and the
        // Automation-denied fallback out of `.focusExisting`'s catch), so both need this same
        // protection — that's why it lives here rather than in just one call site.
        let until = Date().addingTimeInterval(TmuxCore.defaultAttachReplaySettleWindow)
        for mateId in matePaneIds {
            activityMuter?.muteOutput(paneId: mateId, until: until)
        }

        let resolvedApp = resolveOpenNewPreferredApp(preferredApp)
        switch SwitchInvocation.openNewAction(preferredApp: resolvedApp, tmuxPath: tmuxPath, paneId: paneId) {
        case .launchProcess(let executable, let arguments):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    logOpenNewFailure("\(executable) \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
                }
            } catch {
                logOpenNewFailure("\(executable) failed to launch: \(error)")
            }
        case .runScript(let script):
            do {
                _ = try scriptRunner.run(script: script)
            } catch {
                logOpenNewFailure("AppleScript open-new failed: \(error)")
            }
        }
    }

    /// Resolves the caller's preference through `TerminalAppCatalog.resolveOpenNewApp`, supplying
    /// only the AppKit-backed availability check `TmuxCore` can't perform itself (CLAUDE.md:
    /// "TmuxCore must stay free of AppKit") — which apps fall back to the availability-checked
    /// default (no preference, no open-new mechanism at all, or Ghostty's silently-no-ops-if-
    /// uninstalled launch) versus pass through unchanged is the catalog's call, not this call
    /// site's (whole-branch review finding: this used to be a second exhaustive switch over
    /// `SupportedTerminalApp`, duplicating `profile(for:)`'s).
    nonisolated private static func resolveOpenNewPreferredApp(_ preferredApp: SupportedTerminalApp?) -> SupportedTerminalApp {
        TerminalAppCatalog.resolveOpenNewApp(preferred: preferredApp) {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: ghosttyBundleID) != nil
        }
    }

    /// Best-effort logging for a failed open-new (whole-branch review finding: previously
    /// swallowed with no trace at all). A full tooltip UI surfacing this to the user is out of
    /// scope for this fix pass — this is the "log it at minimum" floor.
    nonisolated private static func logOpenNewFailure(_ message: String) {
        FileHandle.standardError.write(Data("panewatch: Switch open-new failed: \(message)\n".utf8))
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
        // TASK-032: routes Preview Input's Send/Enter through `performInlineReply` for
        // whichever pane is active *at submit time* — read fresh here rather than captured at
        // popup-creation time, since this same panel instance is reused across every hover
        // (`popup ?? makePopup()`), so `activePaneID` can only be trusted read live.
        panel.onSubmitInlineReply = { [weak self] text in
            guard let self, let paneID = self.activePaneID else { return }
            self.performInlineReply(paneID: paneID, text: text)
        }
        // TASK-034: the "new hook that fires when the Preview Input text field gains or
        // resigns first responder" the feature spec's `HoverPreviewCloseGate` doc comment
        // describes — routes through the same `updateCloseState()` every mouse-tracking call
        // site does, so the field-focus signal and the mouse-inside signal are never handled
        // by two independently-drifting code paths.
        panel.onInlineReplyFieldFocusChanged = { [weak self] focused in
            guard let self else { return }
            self.fieldFocused = focused
            self.updateCloseState()
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

    /// TASK-020: the `NSClickGestureRecognizer` target-action `attachHoverTracking` wires onto
    /// this Tile's view — `@objc` since gesture-recognizer target-action dispatch goes through
    /// the Objective-C runtime, same requirement `#selector` always has.
    @objc func handleDoubleClick() {
        controller?.tileDoubleClicked(paneID: paneID)
    }
}

/// The Hover Preview Popup window itself — a small non-activating panel, sized per
/// `HoverPopupPlacement.size` (TASK-014 acceptance item 4, not resizable: `.borderless` with no
/// `.resizable` style bit, and nothing in `HoverPreviewController` ever changes its size). See
/// that constant's doc comment for why it's 760x620, not the feature spec's original ~640x420.
/// Body is a live `PreviewClient.terminalView` (`showTerminal(_:)`) or an inline "preview
/// unavailable" state (`showUnavailable()`, acceptance item 5) above a fixed Preview Input
/// footer (TASK-032: a text field plus Send button; TASK-033 adds a Quick Reply chip rail
/// sharing the row) — `HoverPreviewController` swaps the former
/// per `PreviewClient.Outcome` and enables/disables the latter to match.
///
/// Mirrors `FloatingPanel`'s own posture for a window that must never *activate the app* or
/// steal focus from whatever the user was doing elsewhere: `.nonactivatingPanel` plus
/// `becomesKeyOnlyIfNeeded = true` below is the standard AppKit combination for an accessory-app
/// utility panel whose controls can still take keyboard focus on click (the same mechanism
/// Spotlight-style panels use) — `canBecomeKey` used to be hard-overridden `false` (TASK-014)
/// specifically to make that structurally impossible, back when nothing in this popup ever
/// needed keyboard input at all. TASK-032 (ADR-0006) reverses that: Preview Input's text field
/// needs to become first responder to accept typed replies, so `canBecomeKey` now defers to
/// `NSPanel`'s own default (`true`) — `becomesKeyOnlyIfNeeded` is what keeps this scoped to
/// controls that actually request it (the field, the Send button) rather than any click
/// anywhere on the popup, e.g. the live terminal render. `canBecomeMain` stays hard-`false`:
/// nothing here needs main-window status. `hidesOnDeactivate = false` and the
/// `collectionBehavior` that keeps it floating above all Spaces/full-screen apps are unchanged
/// from `FloatingPanel`'s own posture. The read-only guarantee over the *terminal render*
/// specifically is unaffected by this reversal — it never rested on `canBecomeKey` alone even
/// before this task (see `ReadOnlyLocalProcessTerminalView.send`, `PreviewClient.swift, and
/// tmux's own `-r` attach flag, both still fully intact).
@MainActor
final class HoverPreviewPopup: NSPanel {
    private static let cornerRadius: CGFloat = 12
    /// Keeps the terminal/unavailable content off the card's rounded corners.
    private static let contentInset: CGFloat = 10
    /// TASK-032: Preview Input's footer row height, plus the gap above it separating it from
    /// the terminal render — sized to fit a single-line field and button comfortably without
    /// "meaningfully shrinking" the terminal box (feature spec user story 6).
    private static let footerHeight: CGFloat = 28
    private static let footerTopGap: CGFloat = 8
    /// Send is a square icon button, not a wide text button — same height as the row itself, so
    /// it lines up flush with the field's bottom/top edge.
    private static let footerButtonWidth: CGFloat = footerHeight
    private static let footerControlSpacing: CGFloat = 8
    /// TASK-033: the field's fixed width in the "Option A: single row" layout (feature spec
    /// §Further notes) — the chip rail takes the row's leading space and scrolls, the field
    /// keeps this "usable minimum width" at the row's tail alongside Send, rather than the
    /// field stretching to fill whatever space chips don't use. Widened after user feedback
    /// (232, up from 160) — shrinking Send to a square icon button freed up the room.
    private static let footerFieldWidth: CGFloat = 232
    private static let chipSpacing: CGFloat = 8
    /// TASK-033: the fixed, non-configurable Quick Reply set (feature spec "Implementation
    /// decisions") — a plain constant with one call site (this popup's chip rail), not a
    /// `TmuxCore` module (feature spec §Architecture "Deliberately not proposed": it fails the
    /// deletion test as an independent module). Order is the task's own acceptance-item order.
    /// "Continue"/"Stop" were dropped as redundant with "Go on"/"No" — visual cleanup after
    /// user feedback that the eight-chip rail read as cluttered and overflowed its rail.
    /// `label` is what the chip displays; `text` is what's actually sent (`handleChipClicked`).
    /// Identical for every chip except "Ping", which sends lowercase "ping" — a deliberate,
    /// user-requested exception to the "title is the payload" rule the other chips follow.
    private static let quickReplyChips: [(label: String, text: String)] = [
        ("Yes", "Yes"), ("OK", "OK"), ("Go on", "Go on"), ("Looks good", "Looks good"),
        ("Approved", "Approved"), ("No", "No"), ("Ping", "ping")
    ]

    /// Holds whichever of `showTerminal(_:)`/`showUnavailable()` is currently displayed, so
    /// swapping between them is just "remove this container's subviews, add the new one" —
    /// never touches `material` (the background) or the window's own content view. Preview
    /// Input's footer lives outside this container (a sibling in `content`, not a child of
    /// it) specifically so `clearTerminalViews()` below — which empties every subview of this
    /// container except `unavailableLabel` — never sweeps the footer away too.
    private let innerContent: NSView
    private let unavailableLabel: NSTextField
    /// TASK-032: single-line free-text reply field. Cleared whenever a new pane's terminal is
    /// shown (`showTerminal(_:)`) — this same panel instance is reused across every hover
    /// (`HoverPreviewController.popup`), so text left over from a previous pane's unsent reply
    /// must never survive into the next one. Not `private` — the whole-branch-review fix for
    /// TASK-034 (see `makeFirstResponder(_:)` below) needs a test seam to drive real first-
    /// responder transitions against this exact instance (`@testable import PaneWatchApp`, matching
    /// how `PreviewClient`'s own AppKit internals are already tested).
    let inputField: NSTextField
    private let sendButton: NSButton
    /// TASK-033: one button per `quickReplyChips` entry, in order. For most chips the displayed
    /// label and the sent text are identical (`handleChipClicked` reads `sender.title` with no
    /// lookup table to drift out of sync). "Ping" is the one deliberate exception — the button
    /// reads "Ping" but sends lowercase "ping" — so each chip also carries its payload text on
    /// `HoverBackgroundButton.payloadText`, which `handleChipClicked` prefers when present.
    /// Stored (not just built and forgotten) so `setInlineReplyEnabled` can disable them
    /// alongside the field/Send button.
    private let chipButtons: [HoverBackgroundButton]
    /// The chip rail's clipping/scrolling container (whole-branch review fix for TASK-033's
    /// overflow bug, below). Not `private` for the same test-seam reason as `inputField`: a test
    /// needs to inspect `documentView`/`hasHorizontalScroller`/`documentVisibleRect` directly
    /// rather than re-deriving them from `contentView`'s view hierarchy.
    let chipScrollView: NSScrollView
    /// TASK-034 fix (whole-branch review): dedupes `makeFirstResponder(_:)`'s focus signal so
    /// `onInlineReplyFieldFocusChanged` only fires on an actual transition, not on every
    /// first-responder change elsewhere in the window (e.g. clicking Send while the field is
    /// already unfocused would otherwise re-report `false`).
    private var lastReportedFieldFocus = false

    /// Fired with the field's current text on Enter (via `control(_:textView:doCommandBy:)`,
    /// `insertNewline(_:)` only — losing focus by clicking away never submits, per ADR-0006's
    /// "only an exact, explicit string the user approved" posture), a Send click, or
    /// (TASK-033) a Quick Reply chip click, with that chip's exact fixed text
    /// (`handleChipClicked`) — one shared path for every way Preview Input can submit. Whitespace-
    /// only/empty text is *not* filtered here — `HoverPreviewController.performInlineReply` is
    /// the single place that no-ops on it (acceptance item 5), so this popup has no duplicate
    /// copy of that rule to drift out of sync.
    var onSubmitInlineReply: ((String) -> Void)?

    /// TASK-034: fired `true` when the Preview Input field becomes first responder for
    /// editing, `false` when it resigns — `HoverPreviewController` wires this straight into
    /// `HoverPreviewCloseGate`'s `fieldFocused` signal so the popup stays open while the field
    /// has focus, even with the mouse fully outside the popup's bounds.
    var onInlineReplyFieldFocusChanged: ((Bool) -> Void)?

    // swiftlint:disable:next function_body_length
    init() {
        let size = HoverPopupPlacement.size
        let innerContent = NSView(frame: NSRect(
            x: Self.contentInset,
            y: Self.contentInset + Self.footerHeight + Self.footerTopGap,
            width: size.width - Self.contentInset * 2,
            height: size.height - Self.contentInset * 2 - Self.footerHeight - Self.footerTopGap
        ))
        innerContent.autoresizingMask = [.width, .height]
        // `PreviewClient.sizeTerminal(toWindowRows:)` deliberately grows its terminal view
        // taller than this container when the real tmux window has more rows than fit here —
        // clip that overflow rather than letting it spill past the card's rounded corners.
        innerContent.wantsLayer = true
        innerContent.layer?.masksToBounds = true
        self.innerContent = innerContent

        let unavailableLabel = NSTextField(labelWithString: "Preview unavailable")
        unavailableLabel.font = .systemFont(ofSize: 12, weight: .medium)
        unavailableLabel.textColor = NSColor.white.withAlphaComponent(0.6)
        unavailableLabel.alignment = .center
        self.unavailableLabel = unavailableLabel

        // TASK-033 "Option A: single row" layout (feature spec §Further notes): chip rail
        // leads, scrolling horizontally if its content overflows; the field keeps a fixed
        // "usable minimum width" at the row's tail, alongside Send — neither the field nor the
        // rail stretches to fight the other for space.
        let footerWidth = size.width - Self.contentInset * 2
        let fieldX = footerWidth - Self.footerButtonWidth - Self.footerControlSpacing - Self.footerFieldWidth
        let chipRailWidth = fieldX - Self.footerControlSpacing

        let inputField = NSTextField(frame: NSRect(
            x: fieldX,
            y: 0,
            width: Self.footerFieldWidth,
            height: Self.footerHeight
        ))
        inputField.placeholderString = "Reply…"
        inputField.font = .systemFont(ofSize: 12)
        inputField.bezelStyle = .roundedBezel
        // `.roundedBezel`'s single-line cell centers both the placeholder and typed text
        // vertically within whatever frame height it's given — `usesSingleLineMode` keeps that
        // true even though this frame (28pt) is taller than the field's natural intrinsic height.
        inputField.usesSingleLineMode = true
        inputField.autoresizingMask = [.minXMargin]
        inputField.lineBreakMode = .byTruncatingTail
        self.inputField = inputField

        // Square icon button (not a wide "Send" text button) so it reads as a single compact
        // control flush with the field's height, matching the iMessage/Mail "send" affordance —
        // a filled blue square with a white up-arrow glyph, not a bordered push button.
        let sendButton = HoverBackgroundButton(frame: NSRect(
            x: footerWidth - Self.footerButtonWidth,
            y: 0,
            width: Self.footerButtonWidth,
            height: Self.footerHeight
        ))
        sendButton.image = NSImage(
            systemSymbolName: "arrow.up",
            accessibilityDescription: "Send"
        )?.withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        sendButton.imagePosition = .imageOnly
        sendButton.contentTintColor = .white
        sendButton.cornerRadius = 7
        sendButton.restingColor = .systemBlue
        sendButton.hoverColor = NSColor.systemBlue.blended(withFraction: 0.15, of: .white) ?? .systemBlue
        sendButton.autoresizingMask = [.minXMargin]
        self.sendButton = sendButton

        // Each chip button's title is the exact fixed text `handleChipClicked` sends — laid out
        // left-to-right in `quickReplyChips`' order inside `chipContent`, whose width is the sum
        // of every button's natural (padded, pill-shaped) width plus spacing. `chipScrollView`
        // clips that to `chipRailWidth`; if the content is ever wider than the rail (e.g. the
        // catalog grows again), scrolling (trackpad/scroll-wheel) reaches the rest instead of
        // wrapping or clipping them away (acceptance item 3) — `hasHorizontalScroller = true`
        // with `scrollerStyle = .overlay` makes that overflow *discoverable and reachable*: an
        // overlay scroller auto-hides and consumes no layout space, so the rail still reads as a
        // clean single row until the user actually scrolls it. `hasVerticalScroller` stays
        // `false` — this rail never scrolls vertically. `HoverBackgroundButton` draws each chip
        // as a flat pill that highlights on hover, not just on press — a closer visual match for
        // "quick reply chip" than a bordered push-button bezel, and real hover feedback a stock
        // bezel style doesn't give.
        let chipFont = NSFont.systemFont(ofSize: 11, weight: .medium)
        let chipTextColor = NSColor.white.withAlphaComponent(0.92)
        let chipHeight: CGFloat = 22
        let chipHorizontalPadding: CGFloat = 10
        var chipX: CGFloat = 0
        var chipButtons: [HoverBackgroundButton] = []
        for entry in Self.quickReplyChips {
            let attributedTitle = NSAttributedString(string: entry.label, attributes: [
                .font: chipFont,
                .foregroundColor: chipTextColor
            ])
            let chipWidth = ceil(attributedTitle.size().width) + chipHorizontalPadding * 2
            let chip = HoverBackgroundButton(frame: NSRect(
                x: chipX,
                y: (Self.footerHeight - chipHeight) / 2,
                width: chipWidth,
                height: chipHeight
            ))
            chip.attributedTitle = attributedTitle
            chip.attributedAlternateTitle = attributedTitle
            chip.alignment = .center
            chip.payloadText = entry.text
            chipX = chip.frame.maxX + Self.chipSpacing
            chipButtons.append(chip)
        }
        self.chipButtons = chipButtons

        let chipContentWidth = max(chipRailWidth, chipX - Self.chipSpacing)
        let chipContent = NSView(frame: NSRect(x: 0, y: 0, width: chipContentWidth, height: Self.footerHeight))
        chipButtons.forEach { chipContent.addSubview($0) }

        let chipScrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: chipRailWidth, height: Self.footerHeight))
        chipScrollView.documentView = chipContent
        chipScrollView.hasHorizontalScroller = true
        chipScrollView.scrollerStyle = .overlay
        chipScrollView.hasVerticalScroller = false
        chipScrollView.drawsBackground = false
        chipScrollView.horizontalScrollElasticity = .allowed
        chipScrollView.verticalScrollElasticity = .none
        chipScrollView.autoresizingMask = [.width]
        self.chipScrollView = chipScrollView

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

        let footer = NSView(frame: NSRect(
            x: Self.contentInset,
            y: Self.contentInset,
            width: footerWidth,
            height: Self.footerHeight
        ))
        footer.autoresizingMask = [.width]
        footer.addSubview(chipScrollView)
        footer.addSubview(inputField)
        footer.addSubview(sendButton)
        content.addSubview(footer)

        contentView = content

        // Assigned after `super.init` — `self` isn't a valid delegate/target reference before
        // the superclass initializer returns.
        inputField.delegate = self
        sendButton.target = self
        sendButton.action = #selector(handleSendButtonClicked)
        chipButtons.forEach {
            $0.target = self
            $0.action = #selector(handleChipClicked(_:))
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// TASK-034 fix (whole-branch review): `NSTextFieldDelegate.controlTextDidBeginEditing(_:)`
    /// only fires after the user types the *first character* — verified empirically, and
    /// contrary to what this file used to claim — not when `inputField` simply becomes first
    /// responder via a click with no typing yet. That gap let the close-timer fire out from
    /// under an in-progress reply (click the field, move the mouse out before typing, `fieldFocused`
    /// stays `false`), exactly what TASK-034 was supposed to prevent.
    ///
    /// `makeFirstResponder(_:)` is the one choke point AppKit routes every focus transition
    /// through for this window, including a plain click into `inputField` — unlike the delegate
    /// callback, it fires on the very first responder change, before any typing. Reading
    /// `firstResponder` *after* `super` and comparing against both `inputField` and
    /// `inputField.currentEditor()` is required because an editable `NSTextField` doesn't hold
    /// first-responder status itself once editing starts — the window hands that off to the
    /// shared field editor (an `NSTextView`), so a click-then-hover-away with no typing lands on
    /// `inputField` itself, while typing then hovering away lands on the field editor. Dedupes
    /// through `lastReportedFieldFocus` so a first-responder change elsewhere in the window
    /// (e.g. clicking Send) doesn't re-report a signal that hasn't actually changed.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        let focused = firstResponder === inputField || firstResponder === inputField.currentEditor()
        if focused != lastReportedFieldFocus {
            lastReportedFieldFocus = focused
            onInlineReplyFieldFocusChanged?(focused)
        }
        return result
    }

    /// Resets the dedupe flag above whenever this popup closes — every `orderOut` call site
    /// (`HoverPreviewController.closeAndDetachClient()`/`tearDownActivePreviewSynchronously()`)
    /// also resets its own `fieldFocused` to `false`, and leaving this one stale would desync
    /// the pair: the window can still hold the field editor as first responder after being
    /// ordered out, so without this reset the next popup use starts from a `true` dedupe state
    /// that no longer reflects reality.
    override func orderOut(_ sender: Any?) {
        lastReportedFieldFocus = false
        super.orderOut(sender)
    }

    /// Displays a live terminal view (`PreviewClient.terminalView`), replacing whatever this
    /// popup was showing before — a fresh `PreviewClient` per `open(paneID:tileView:)` means a
    /// fresh view here too, so the previous pane's frame never lingers on screen while the new
    /// attach is still spinning up. Also re-enables Preview Input (acceptance item 6: it's
    /// disabled only while `showUnavailable()` is active) and clears any leftover text from a
    /// previous pane's unsent reply (this popup instance is reused across every hover).
    ///
    /// Only `.width` autoresizes, not `.height`: this starting frame is `innerContent.bounds`
    /// (so `PreviewClient.start(paneID:)` can read a real `terminal.rows` baseline before it
    /// knows the target pane's window height), but `PreviewClient.sizeTerminal(toWindowRows:)`
    /// then grows `view.frame`'s height past this container's own — matching `.height` here
    /// would fight that by snapping it back down were `innerContent` ever to resize (it never
    /// does; the popup is fixed-size, but this keeps the intent explicit rather than relying on
    /// that never happening).
    func showTerminal(_ view: NSView) {
        unavailableLabel.isHidden = true
        clearTerminalViews()
        // `addSubview` before `frame =`: `ReadOnlyLocalProcessTerminalView.viewDidMoveToSuperview()`
        // hides SwiftTerm's permanent scroller as soon as the view lands in a superview, and that
        // has to happen *before* the frame assignment below triggers `processSizeChange` — reserve
        // order left `cols` computed against the still-visible scroller's width, permanently
        // losing the columns the hide was meant to reclaim (nothing afterward re-triggers a resize).
        innerContent.addSubview(view)
        view.frame = innerContent.bounds
        view.autoresizingMask = [.width]
        inputField.stringValue = ""
        setInlineReplyEnabled(true)
    }

    /// Acceptance item 5: the spawn failed outright — show the inline state instead of
    /// whatever `showTerminal(_:)` last displayed (a blank/frozen terminal view). Also disables
    /// Preview Input (acceptance item 6) — there is no live pane to send a reply to.
    func showUnavailable() {
        clearTerminalViews()
        unavailableLabel.isHidden = false
        setInlineReplyEnabled(false)
    }

    private func setInlineReplyEnabled(_ enabled: Bool) {
        inputField.isEnabled = enabled
        sendButton.isEnabled = enabled
        chipButtons.forEach { $0.isEnabled = enabled }
    }

    private func clearTerminalViews() {
        for subview in innerContent.subviews where subview !== unavailableLabel {
            subview.removeFromSuperview()
        }
    }

    @objc private func handleSendButtonClicked() {
        submitInlineReply()
    }

    /// TASK-033: fires an Inline Reply with the clicked chip's fixed payload text — `payloadText`
    /// when the chip set one (currently only "Ping", which sends lowercase "ping" rather than
    /// its displayed label), falling back to `sender.title` for every other chip, where label
    /// and payload are identical by construction. No typing, and no interaction with `inputField`
    /// at all, unlike `submitInlineReply()`. Reuses the same `onSubmitInlineReply` closure
    /// `HoverPreviewController.performInlineReply` is wired to (TASK-032): no new send path, no
    /// new pure logic, per this task's slice.
    @objc private func handleChipClicked(_ sender: NSButton) {
        let text = (sender as? HoverBackgroundButton)?.payloadText ?? sender.title
        onSubmitInlineReply?(text)
    }

    private func submitInlineReply() {
        let text = inputField.stringValue
        inputField.stringValue = ""
        onSubmitInlineReply?(text)
    }
}

/// TASK-032: routes Enter specifically to `submitInlineReply()` — plain `NSTextField`
/// target/action also fires when the field simply *ends editing* (e.g. clicking away), which
/// would send whatever the user typed and then abandoned, contradicting ADR-0006's "only an
/// exact, explicit string the user approved" posture (feature spec user story 5). Intercepting
/// `insertNewline(_:)` here and leaving every other command (including focus loss) unhandled —
/// `return false` — keeps that path inert.
extension HoverPreviewPopup: NSTextFieldDelegate {
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        submitInlineReply()
        return true
    }
}
