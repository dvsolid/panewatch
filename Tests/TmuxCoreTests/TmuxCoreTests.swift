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
