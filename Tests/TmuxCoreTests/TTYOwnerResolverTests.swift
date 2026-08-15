import Foundation
import Testing
@testable import TmuxCore

/// Exercises `ProcessTableTTYOwnerResolver` — the ancestor-walk mirror of
/// `DescendantProcessInspectorTests`. Each test writes a tiny fake `ps`-shaped shell script to a
/// temp file and points the resolver at it via the `psExecutableURL` test seam, same pattern as
/// `DescendantProcessInspectorTests`.
@Suite struct TTYOwnerResolverTests {
    /// Writes an executable shell script whose body is `body`, returning its file URL.
    private func makeFakePS(body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fake-ps-\(UUID().uuidString)")
        let script = "#!/bin/sh\n\(body)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func ownerAncestorChainIncludingGhosttyResolvesToGhostty() throws {
        // pid 300 owns ttys005 (the tty being resolved); its parent is a login shell, whose
        // parent is Ghostty itself — mirrors the real ancestor chain observed on the dev
        // machine (login -> Ghostty), see this task's Implementation notes.
        let ps = try makeFakePS(body: """
        echo '100 1 ??      /Applications/Ghostty.app/Contents/MacOS/ghostty'
        echo '200 100 ttys005 login -flp dmitryv /bin/zsh'
        echo '300 200 ttys005 -zsh'
        """)
        let resolver = ProcessTableTTYOwnerResolver(psExecutableURL: ps)

        let result = resolver.resolveOwningApp(tty: "ttys005")

        #expect(result == .ghostty(pid: 100))
    }

    @Test func ownerAncestorChainIncludingITerm2ResolvesToITerm2() throws {
        let ps = try makeFakePS(body: """
        echo '110 1 ??      /Applications/iTerm.app/Contents/MacOS/iTerm2'
        echo '210 110 ttys006 login -flp dmitryv /bin/zsh'
        echo '310 210 ttys006 -zsh'
        """)
        let resolver = ProcessTableTTYOwnerResolver(psExecutableURL: ps)

        let result = resolver.resolveOwningApp(tty: "ttys006")

        #expect(result == .iTerm2(pid: 110))
    }

    @Test func ownerAncestorChainIncludingTerminalAppResolvesToTerminalApp() throws {
        let ps = try makeFakePS(body: """
        echo '120 1 ??      /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal'
        echo '220 120 ttys007 login -flp dmitryv /bin/zsh'
        echo '320 220 ttys007 -zsh'
        """)
        let resolver = ProcessTableTTYOwnerResolver(psExecutableURL: ps)

        let result = resolver.resolveOwningApp(tty: "ttys007")

        #expect(result == .terminalApp(pid: 120))
    }

    @Test func ancestorChainWithNoSupportedAppReturnsNil() throws {
        // Ancestor chain tops out at an unrelated launcher, never any of the three supported
        // terminal apps — e.g. a pane reached via ssh from an unrecognized wrapper.
        let ps = try makeFakePS(body: """
        echo '130 1 ??      /usr/libexec/some-unrelated-launcher'
        echo '230 130 ttys008 login -flp dmitryv /bin/zsh'
        echo '330 230 ttys008 -zsh'
        """)
        let resolver = ProcessTableTTYOwnerResolver(psExecutableURL: ps)

        let result = resolver.resolveOwningApp(tty: "ttys008")

        #expect(result == nil)
    }
}
