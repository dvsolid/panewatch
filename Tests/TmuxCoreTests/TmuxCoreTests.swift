import Testing
@testable import TmuxCore

/// Guards the one rule SPEC.md §6 calls out as easy to get wrong: the tmux binary must be
/// resolved by absolute path. Invoking bare `tmux` picks up the user's zsh plugin alias
/// (`_zsh_tmux_plugin_run`), which does not resolve from a non-interactive shell.
///
/// Falsifiable: changing `defaultTmuxPath` to `"tmux"` fails this test.
@Test func tmuxPathIsAbsolute() {
    #expect(TmuxCore.defaultTmuxPath.hasPrefix("/"))
}

/// Falsifiable: hardcoding the Apple Silicon Homebrew path back in (ignoring `isExecutableFile`)
/// fails this — the resolver must actually pick the candidate the predicate reports as present.
@Test func resolveTmuxPathPicksFirstExistingCandidate() {
    let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    let resolved = TmuxCore.resolveTmuxPath(candidates: candidates) { $0 == "/usr/local/bin/tmux" }
    #expect(resolved == "/usr/local/bin/tmux")
}

/// Falsifiable: returning `nil`/crashing when nothing exists on disk fails this — CI and
/// tmux-less machines must still get a usable (if wrong) default.
@Test func resolveTmuxPathFallsBackToFirstCandidateWhenNoneExist() {
    let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
    let resolved = TmuxCore.resolveTmuxPath(candidates: candidates) { _ in false }
    #expect(resolved == "/opt/homebrew/bin/tmux")
}
