import Foundation
import Testing
@testable import TmuxCore
@testable import PaneWatchApp

/// Exercises `UserDefaultsDockSideStore` — the real `DockSideStore` adapter (TASK-030) — against
/// a scratch `UserDefaults` suite rather than `.standard`, so a test run never touches (or is
/// polluted by) this machine's real defaults domain. First use of `UserDefaults` anywhere in this
/// codebase (feature spec § Architecture, `DockSideStore`).
@Suite struct UserDefaultsDockSideStoreTests {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "com.panewatch.tests.dockside.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func loadDefaultsToRightWhenNeverSet() {
        let store = UserDefaultsDockSideStore(defaults: makeScratchDefaults())

        #expect(store.load() == .right)
    }

    @Test func saveThenLoadRoundTripsTheChosenSide() {
        let store = UserDefaultsDockSideStore(defaults: makeScratchDefaults())

        store.save(.left)

        #expect(store.load() == .left)
    }
}
