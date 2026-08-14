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
    private let panel = FloatingPanel()
    private let engine: StatusBarEngine
    /// Re-renders on `probeInterval` so a Tile's Fading color keeps advancing with wall-clock
    /// time even when its pane produces no new output — this is unrelated to how
    /// `PollingActivitySource` itself samples tmux (that timer lives inside the adapter,
    /// hidden behind `ActivitySource` — ADR-0001) and stays correct under any future adapter.
    private var refreshTimer: Timer?
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
        return StatusBarEngine(
            discovery: PaneDiscovery(gateway: gateway),
            activitySource: PollingActivitySource(gateway: gateway)
        )
    }()) {
        self.engine = engine
    }

    /// Places the Menu Bar Icon, hides the Dock icon, runs one discovery pass to populate the
    /// panel, and starts the re-render timer that keeps Activity Phases live. Call once from
    /// `applicationDidFinishLaunching`.
    ///
    /// Discovery itself is still a single pass, not a re-scanning timer: live topology
    /// reconciliation on `discoveryInterval` is TASK-006. This slice's timer only re-derives
    /// phases for the pane set discovery already found.
    func start() {
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "rectangle.portrait", accessibilityDescription: "tmuxer")
            image?.isTemplate = true
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        refreshTiles()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: TmuxCore.defaultProbeInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTiles() }
        }
    }

    private func refreshTiles() {
        do {
            panel.render(try engine.scanTiles())
        } catch {
            // No live tmux server, or the spawn failed — show an empty bar rather than
            // crashing the app. TASK-006 will need real error/retry handling for the discovery
            // timer loop; a one-shot launch scan for this slice doesn't need it yet.
            panel.render([])
        }
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
