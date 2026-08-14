/// Namespace placeholder for the tmuxer core.
///
/// Scaffolding only — this exists so `swift test` has something to build before the first
/// real task lands. See SPEC.md §2 (discovery), §3 (`ActivitySource`), §7 (data model) for
/// what actually goes here.
public enum TmuxCore {
    /// Identifier of the tmux binary this package shells out to.
    ///
    /// SPEC.md §6: never invoke bare `tmux` — the user's interactive `tmux` is a zsh plugin
    /// alias that does not resolve non-interactively.
    public static let defaultTmuxPath = "/opt/homebrew/bin/tmux"
}
