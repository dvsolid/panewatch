import CoreGraphics

/// Asks the window server whether a window is actually on screen — the one signal that
/// distinguishes a healthy `FloatingPanel` from one AppKit thinks is shown but the window
/// server has stranded (TASK-040). A seam so a fake can force "off screen" in a scratch run.
///
/// Asynchronous by nature: the flag lags every order call (measured: absent synchronously after
/// `orderFrontRegardless()`, present by the next main-queue turn), so `PanelStrandingPolicy`
/// only believes it after a settle interval.
@MainActor
protocol WindowServerProbe {
    /// `kCGWindowIsOnscreen` for `windowNumber`; `nil` when the window or the flag is absent.
    func isOnScreen(windowNumber: Int) -> Bool?
}

/// `CGWindowListCopyWindowInfo` for one of this process's own windows — needs no permission.
struct CGWindowServerProbe: WindowServerProbe {
    func isOnScreen(windowNumber: Int) -> Bool? {
        guard windowNumber > 0,
              let windows = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowNumber)) as? [[String: Any]],
              let entry = windows.first(where: { ($0[kCGWindowNumber as String] as? Int) == windowNumber })
        else { return nil }
        return entry[kCGWindowIsOnscreen as String] as? Bool
    }
}
