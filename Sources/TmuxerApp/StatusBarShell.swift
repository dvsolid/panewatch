import AppKit
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
    private let panel: FloatingPanel
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
    private let quitMenu: NSMenu = {
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
        return menu
    }()

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
    }()) {
        self.engine = engine
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
            let image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "tmuxer")
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
    /// `tmuxer-preview-*` grouped session on the tmux server indefinitely, since neither the
    /// async close path nor the next-hover best-effort cleanup ever gets a chance to run once
    /// the process has exited.
    func prepareForTermination() {
        panel.tearDownActivePreviewForTermination()
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showQuitMenu()
        } else {
            panel.toggleVisibility()
        }
    }

    /// Attaching a menu permanently to the status item would make left-click open it instead
    /// of toggling the panel — assign it only for the duration of this one right-click.
    private func showQuitMenu() {
        guard let item = statusItem else { return }
        item.menu = quitMenu
        item.button?.performClick(nil)
        item.menu = nil
    }
}
