import AppKit

// No app bundle / Info.plist — this runs as a raw SPM executable (CLAUDE.md: no Xcode on
// this machine). `AppDelegate.applicationDidFinishLaunching` sets `.accessory` activation
// policy itself, so the Menu Bar Icon appears with no Dock icon regardless of bundling.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
