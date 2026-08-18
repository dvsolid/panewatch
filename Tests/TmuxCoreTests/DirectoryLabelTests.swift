import Testing
@testable import TmuxCore

/// Exercises `DirectoryLabel.brief(of:)` — the pure leaf-name half of TASK-035's Directory Row
/// (feature spec § Architecture, `DirectoryLabel`). Headless, no fixtures needed.
@Suite struct DirectoryLabelTests {
    @Test func returnsTheLastComponentOfANormalAbsolutePath() {
        #expect(DirectoryLabel.brief(of: "/Users/user/Projects/acme/widget-advisor") == "widget-advisor")
    }

    @Test func stripsATrailingSlashBeforeTakingTheLastComponent() {
        #expect(DirectoryLabel.brief(of: "/Users/user/Projects/acme/widget-advisor/") == "widget-advisor")
    }

    @Test func returnsRootUnchangedForTheRootPath() {
        #expect(DirectoryLabel.brief(of: "/") == "/")
    }

    @Test func returnsEmptyForAnEmptyPath() {
        #expect(DirectoryLabel.brief(of: "") == "")
    }
}
