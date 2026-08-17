import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shell = StatusBarShell()

    func applicationDidFinishLaunching(_ notification: Notification) {
        shell.start()
    }

    /// Whole-branch review finding: without this, a hover popup left open when the app quits
    /// leaks its `panewatch-preview-*` grouped tmux session indefinitely — see
    /// `StatusBarShell.prepareForTermination()`.
    func applicationWillTerminate(_ notification: Notification) {
        shell.prepareForTermination()
    }
}
