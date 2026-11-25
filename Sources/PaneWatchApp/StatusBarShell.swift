import AppKit
import os
import TmuxCore

/// The AppKit adapter at the boundary between `StatusBarEngine` and the OS: owns the Menu Bar
/// Icon and the non-activating floating `FloatingPanel`. Makes no tmux or timing decisions
/// itself — see feature spec § Architecture, `StatusBarShell`.
///
/// Why deep (inverted): the reason this module exists isn't hidden behavior, it's isolation —
/// without this seam, `AppKit` imports creep into `TmuxCore` and everything above stops being
/// headlessly testable.
@MainActor
final class StatusBarShell: NSObject {
    private var statusItem: NSStatusItem?
    /// Replaceable (TASK-040): a panel the window server has stranded off-screen is discarded
    /// for a freshly created one — see `healPanel(trigger:)`.
    private var panel: FloatingPanel
    private let windowServerProbe: any WindowServerProbe
    /// A heal already ran for the current show attempt — `PanelStrandingPolicy` turns a second
    /// stranded reading into `.giveUp` rather than a rebuild loop. Reset whenever the user's
    /// click shows a hidden panel (or gives up and hides it), so every attempt starts fresh.
    private var healedThisAttempt = false
    private var settleCheckTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "PaneWatch", category: "FloatingPanel")
    private let engine: StatusBarEngine
    /// Re-runs discovery on `discoveryInterval` (TASK-006) — the only timer that spawns
    /// `list-panes -a`. New/closed agent panes join or leave the Tile list on this cadence,
    /// via `StatusBarEngine.reconcile(_:)`.
    private var discoveryTimer: Timer?
    /// Re-renders on `probeInterval` so a Tile's Fading color keeps advancing with wall-clock
    /// time even when its pane produces no new output — via `StatusBarEngine.tiles(_:)`, which
    /// re-derives phases for the pane set `discoveryTimer` last found, with no new discovery
    /// spawn. Unrelated to how `PollingActivitySource` itself samples tmux (that timer lives
    /// inside the adapter, hidden behind `ActivitySource` — ADR-0001) and stays correct under
    /// any future adapter.
    private var phaseRefreshTimer: Timer?

    init(engine: StatusBarEngine = {
        // One `TmuxGateway` shared by discovery and activity polling — both are real
        // tmux-talking collaborators built at this composition root, per `StatusBarEngine`'s
        // own doc comment on why `TmuxCore` never defaults them.
        let gateway = ProcessTmuxGateway()
        // TASK-029: the real stack, composition-root wired — `ControlModeActivitySource`
        // (event-driven, SPEC §3.2) as primary, falling back to the already-proven
        // `PollingActivitySource` (SPEC §3.1) on the failure signal `FailableActivitySource`
        // defines (never having confirmed a working attach). `secondary` sits idle — its own
        // `probeInterval` timer runs from `init`, but with an empty watched-pane set until
        // `FallbackActivitySource` actually switches, so it spawns no `capture-pane` calls
        // and has no UI-visible effect unless/until the switch happens.
        let activitySource = FallbackActivitySource(
            primary: ControlModeActivitySource(launcher: ProcessControlModeLauncher(), tmuxPath: gateway.tmuxPath),
            secondary: PollingActivitySource(gateway: gateway)
        )
        return StatusBarEngine(
            discovery: PaneDiscovery(gateway: gateway),
            activitySource: activitySource
        )
    }(), windowServerProbe: any WindowServerProbe = CGWindowServerProbe()) {
        self.engine = engine
        self.windowServerProbe = windowServerProbe
        // Shares `engine`'s own `ActivityStateStore` with the Hover Preview Popup so its
        // `PreviewClientLifecycle` can mute the popup's own zoom-induced repaint out of
        // activity tracking — see `StatusBarEngine.activityStateStore`'s doc comment.
        self.panel = FloatingPanel(activityMuter: engine.activityStateStore)
    }

    /// Places the Menu Bar Icon, hides the Dock icon, runs one discovery pass to populate the
    /// panel, and starts both live timers: `discoveryTimer` re-scans topology on
    /// `discoveryInterval`, `phaseRefreshTimer` re-renders Activity Phases on `probeInterval`.
    /// Call once from `applicationDidFinishLaunching`.
    func start() {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "PaneWatch")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        reconcileTiles()
        discoveryTimer = Timer.scheduledTimer(withTimeInterval: TmuxCore.defaultDiscoveryInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reconcileTiles() }
        }
        phaseRefreshTimer = Timer.scheduledTimer(withTimeInterval: TmuxCore.defaultProbeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPhases() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    /// TASK-037: after the Mac wakes from sleep, Claude Code's own reconnect-after-sleep banner
    /// and screen redraw are genuine bytes, correctly reported as activity by
    /// `ControlModeActivitySource` — this mute is a deliberate tradeoff on top of correct
    /// detection, not a bug fix for broken detection. See `TmuxCore.defaultWakeMuteWindow` and
    /// `ActivityStateStore.muteAllOutput` for the full rationale. No explicit `removeObserver`
    /// needed — `StatusBarShell` lives for the whole process lifetime (owned by `AppDelegate`),
    /// same as the untorn-down `discoveryTimer`/`phaseRefreshTimer`.
    @objc private func systemDidWake() {
        engine.activityStateStore.muteAllOutput(until: Date().addingTimeInterval(TmuxCore.defaultWakeMuteWindow))
    }

    /// Re-runs discovery and renders the reconciled Tile list. The only call that spawns
    /// `list-panes -a` — see `discoveryTimer`.
    private func reconcileTiles() {
        do {
            panel.render(try engine.reconcile())
        } catch {
            // No live tmux server, or the spawn failed — show an empty bar rather than
            // crashing the app. A future task will need real error/retry handling for the
            // discovery timer loop; this slice doesn't need it yet.
            panel.render([])
        }
    }

    /// Re-derives Activity Phases for the pane set `reconcileTiles` last found, with no new
    /// discovery spawn, and renders them. See `phaseRefreshTimer`.
    private func refreshPhases() {
        panel.render(engine.tiles())
    }

    /// Forwarded from `AppDelegate.applicationWillTerminate` — whole-branch review finding:
    /// without this, quitting the app (or crashing) with a hover popup open leaves its
    /// `panewatch-preview-*` grouped session on the tmux server indefinitely, since neither the
    /// async close path nor the next-hover best-effort cleanup ever gets a chance to run once
    /// the process has exited.
    func prepareForTermination() {
        panel.tearDownActivePreviewForTermination()
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showStatusItemMenu()
        } else {
            togglePanel()
        }
    }

    // MARK: - Stranded-panel self-heal (TASK-040)

    /// Shows or hides the panel — except that a panel AppKit calls visible but the window server
    /// reports off screen is replaced and shown instead of hidden (that click heals, it does not
    /// toggle). The window server's verdict is never read synchronously after an order call; see
    /// `PanelStrandingPolicy.settleInterval`.
    private func togglePanel() {
        switch PanelStrandingPolicy.decide(.click, strandingInput()) {
        case .show:
            healedThisAttempt = false
            showPanel()
        case .hide:
            panel.hide()
        case .heal:
            healPanel(trigger: "click")
        case .giveUp:
            logGaveUp(trigger: "click")
            panel.hide()
            healedThisAttempt = false
        case .none:
            break
        }
    }

    private func showPanel() {
        panel.show()
        scheduleSettleCheck()
    }

    /// The delayed re-check after each show: heals a panel that was stranded on a show the click
    /// path never revisits. A stale reading is harmless — the next click still catches it.
    private func scheduleSettleCheck() {
        settleCheckTask?.cancel()
        settleCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PanelStrandingPolicy.settleInterval + 0.05))
            guard !Task.isCancelled else { return }
            self?.runSettleCheck()
        }
    }

    private func runSettleCheck() {
        switch PanelStrandingPolicy.decide(.settleCheck, strandingInput()) {
        case .heal: healPanel(trigger: "settle check")
        case .giveUp: logGaveUp(trigger: "settle check")
        case .show, .hide, .none: break
        }
    }

    private func strandingInput() -> PanelStrandingPolicy.Input {
        PanelStrandingPolicy.Input(
            appKitVisible: panel.isVisible,
            windowServerOnScreen: windowServerProbe.isOnScreen(windowNumber: panel.windowNumber),
            timeSinceShown: panel.shownAt.map { Date().timeIntervalSince($0) } ?? .infinity,
            alreadyHealed: healedThisAttempt
        )
    }

    /// Replaces the stranded panel with a fresh one — the only remedy observed to work — and
    /// shows it with the current Tiles; Dock Side comes from `dockSideStore` as for any new panel.
    private func healPanel(trigger: String) {
        let reported = windowServerProbe.isOnScreen(windowNumber: panel.windowNumber)
        Self.logger.notice("""
            healing stranded panel (\(trigger, privacy: .public)): AppKit isVisible=true, \
            windowServerOnScreen=\(reported.map(String.init(describing:)) ?? "absent", privacy: .public), \
            windowNumber=\(self.panel.windowNumber, privacy: .public)
            """)
        let stranded = panel
        panel = FloatingPanel(activityMuter: engine.activityStateStore)
        panel.render(engine.tiles())
        stranded.retire()
        healedThisAttempt = true
        showPanel()
    }

    private func logGaveUp(trigger: String) {
        Self.logger.error("replacement panel is also off screen (\(trigger, privacy: .public)); not healing again this attempt")
    }

    /// Attaching a menu permanently to the status item would make left-click open it instead
    /// of toggling the panel — assign it only for the duration of this one right-click. Rebuilds
    /// the menu fresh on every call (TASK-030) so the Dock Side items' checkmarks always reflect
    /// `panel.dockSide` as it stands right now, not whatever it was the last time the app right-
    /// clicked.
    private func showStatusItemMenu() {
        guard let item = statusItem else { return }
        item.menu = buildStatusItemMenu()
        item.button?.performClick(nil)
        item.menu = nil
    }

    /// TASK-030: two radio-style items (checkmark on the active side) rather than one toggle
    /// item whose title/label swaps — chosen so "reflecting the currently active side" (this
    /// task's acceptance criterion) is directly observable as menu state, not just inferable
    /// from a label's wording.
    private func buildStatusItemMenu() -> NSMenu {
        let menu = NSMenu()

        let dockLeft = NSMenuItem(title: "Dock Left", action: #selector(dockLeftSelected), keyEquivalent: "")
        dockLeft.target = self
        dockLeft.state = panel.dockSide == .left ? .on : .off
        menu.addItem(dockLeft)

        let dockRight = NSMenuItem(title: "Dock Right", action: #selector(dockRightSelected), keyEquivalent: "")
        dockRight.target = self
        dockRight.state = panel.dockSide == .right ? .on : .off
        menu.addItem(dockRight)

        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
        return menu
    }

    @objc private func dockLeftSelected() {
        panel.setDockSide(.left)
    }

    @objc private func dockRightSelected() {
        panel.setDockSide(.right)
    }
}
