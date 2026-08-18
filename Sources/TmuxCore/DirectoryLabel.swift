import Foundation

/// Derives a Tile's brief Working Directory display value from a pane's full `currentPath`
/// (feature spec § Architecture, `DirectoryLabel`). Pure, headlessly testable, and named as
/// its own concept — `TileState.init`'s sole call site could inline `NSString
/// .lastPathComponent` directly (it's already in `TmuxCore`, so extraction isn't needed for
/// testability alone), but this way the root/trailing-slash/empty-path edge cases have one
/// documented, independently-tested home instead of being folded silently into
/// `TileState`'s own tests.
public enum DirectoryLabel {
    /// The leaf directory name: `path`'s last path component, with any trailing slash
    /// stripped first. The root path `/` has no leaf narrower than itself, so it returns
    /// unchanged. An empty path returns empty — tmux always reports an absolute
    /// `pane_current_path` in practice, so this is a defined-but-inert edge case.
    public static func brief(of path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
