import AppKit
import Foundation
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

    init(
        gateway: any TmuxGateway = ProcessTmuxGateway(),
        tmuxPath: String = TmuxCore.defaultTmuxPath,
        ttyOwnerResolver: any TTYOwnerResolver = ProcessTableTTYOwnerResolver(),
        switchPlanner: SwitchActionPlanner = SwitchActionPlanner(),
        scriptRunner: any AppleScriptRunner = OSAScriptRunner()
    ) {
        self.gateway = gateway
        self.tmuxPath = tmuxPath
        self.paneDiscovery = PaneDiscovery(gateway: gateway)
        self.clientDiscovery = ClientDiscovery(gateway: gateway)
        self.ttyOwnerResolver = ttyOwnerResolver
        self.switchPlanner = switchPlanner
        self.scriptRunner = scriptRunner
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
    /// `tmuxer-preview-*` session on the tmux server indefinitely, since neither a detached
    /// task nor the next-hover best-effort cleanup ever gets a chance to run). See
    /// `PreviewClient.stopSynchronously()` for why this can't reuse the async `close()` path.
    func tearDownActivePreviewSynchronously() {
        cancelDwell()
        cancelClose()
        activePaneID = nil
        popup?.orderOut(nil)
        previewClient?.stopSynchronously()
        previewClient = nil
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
        FileHandle.standardError.write(Data("tmuxer: double-click received for \(paneID)\n".utf8))
        let teardown = closeAndDetachClient()

        let gateway = gateway
        let tmuxPath = tmuxPath
        let paneDiscovery = paneDiscovery
        let clientDiscovery = clientDiscovery
        let ttyOwnerResolver = ttyOwnerResolver
        let switchPlanner = switchPlanner
        let scriptRunner = scriptRunner

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
                scriptRunner: scriptRunner
            )
        }
    }

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
        scriptRunner: any AppleScriptRunner
    ) {
        // The pane can have vanished between the double-click and this resolve (e.g. the agent
        // exited) — silently do nothing rather than act on stale/absent data, the same posture
        // `PreviewClientLifecycle.prepareGroupSession` takes for a dead pane.
        guard let target = resolveTarget(paneID: paneID, paneDiscovery: paneDiscovery) else { return }
        let attachedClient = resolveAttachedClient(
            target: target,
            clientDiscovery: clientDiscovery,
            ttyOwnerResolver: ttyOwnerResolver
        )

        let plan = switchPlanner.plan(target: target, attachedClient: attachedClient)
        FileHandle.standardError.write(Data("tmuxer: switch plan for \(paneID) -> \(plan), attachedClient=\(String(describing: attachedClient))\n".utf8))
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
                // here even though the owning app is known.
                performOpenNew(preferredApp: nil, tmuxPath: tmuxPath, paneId: target.paneId, scriptRunner: scriptRunner)
            }
        case .openNew(let paneId):
            performOpenNew(preferredApp: attachedClient?.owningApp, tmuxPath: tmuxPath, paneId: paneId, scriptRunner: scriptRunner)
        }
    }

    /// Finds the `RawPane` matching `paneID` in a fresh `PaneDiscovery.scan()` and builds its
    /// `PaneTarget` — this task's notes are explicit that this lookup gets no dedicated
    /// `TmuxCore` module of its own, just a filter over an existing scan at double-click time.
    nonisolated private static func resolveTarget(paneID: String, paneDiscovery: PaneDiscovery) -> PaneTarget? {
        guard let panes = try? paneDiscovery.scan(), let pane = panes.first(where: { $0.paneId == paneID }) else {
            return nil
        }
        return PaneTarget(paneId: pane.paneId, sessionName: pane.sessionName, windowIndex: pane.windowIndex, paneIndex: pane.paneIndex, currentPath: pane.currentPath)
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
        scriptRunner: any AppleScriptRunner
    ) {
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
        FileHandle.standardError.write(Data("tmuxer: Switch open-new failed: \(message)\n".utf8))
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
/// Body is either a live `PreviewClient.terminalView` (`showTerminal(_:)`) or an inline "preview
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
        view.frame = innerContent.bounds
        view.autoresizingMask = [.width]
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
