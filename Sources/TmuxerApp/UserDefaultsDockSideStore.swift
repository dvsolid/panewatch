import Foundation
import TmuxCore

/// The live `DockSideStore`: backed by `UserDefaults`. First use of `UserDefaults` anywhere in
/// this codebase (feature spec § Architecture, `DockSideStore`). Adapter lives here, not in
/// TmuxCore, mirroring `OSAScriptRunner`/`AppleScriptRunner`'s protocol-plus-concrete-adapter
/// split.
public struct UserDefaultsDockSideStore: DockSideStore {
    private static let key = "dockSide"
    private let defaults: UserDefaults

    /// Test seam: point at a scratch `UserDefaults` suite instead of the real `.standard`
    /// domain — same pattern as `ProcessTmuxGateway.tmuxPath`/`OSAScriptRunner.osascriptExecutableURL`.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Falls back to `.right` when never set — matches `FloatingPanel`'s original hardcoded
    /// right-edge posture, so a fresh install (or a defaults domain wiped between runs) keeps
    /// today's behavior rather than surprising an existing user with an unrequested left dock.
    public func load() -> DockSide {
        guard let raw = defaults.string(forKey: Self.key), let side = DockSide(rawValue: raw) else {
            return .right
        }
        return side
    }

    public func save(_ side: DockSide) {
        defaults.set(side.rawValue, forKey: Self.key)
    }
}
