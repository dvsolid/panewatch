/// Persistence seam for the current `DockSide`, surviving app relaunch. `UserDefaultsDockSideStore`
/// (PaneWatchApp) is the real adapter; tests inject a fake instead of touching the real `UserDefaults`
/// domain — mirrors `TmuxGateway`/`AppleScriptRunner`'s protocol-plus-concrete-adapter split.
/// Feature spec § Architecture, `DockSideStore`.
public protocol DockSideStore {
    /// Falls back to `.right` when never set.
    func load() -> DockSide
    func save(_ side: DockSide)
}
