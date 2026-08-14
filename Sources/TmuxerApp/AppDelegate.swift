import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let shell = StatusBarShell()

    func applicationDidFinishLaunching(_ notification: Notification) {
        shell.start()
    }
}
