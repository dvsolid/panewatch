import AppKit

/// The AppKit adapter at the boundary between the (future) `StatusBarEngine` and the OS: owns
/// the Menu Bar Icon and the non-activating floating `FloatingPanel`. Makes no tmux or timing
/// decisions itself — see feature spec § Architecture, `StatusBarShell`.
///
/// Why deep (inverted): the reason this module exists isn't hidden behavior, it's isolation —
/// without this seam, `AppKit` imports creep into `TmuxCore` and everything above stops being
/// headlessly testable.
@MainActor
final class StatusBarShell: NSObject {
    private var statusItem: NSStatusItem?
    private let panel = FloatingPanel()
    private let quitMenu: NSMenu = {
        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
        return menu
    }()

    /// Places the Menu Bar Icon and hides the Dock icon. Call once from
    /// `applicationDidFinishLaunching`.
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
