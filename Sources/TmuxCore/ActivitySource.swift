import Foundation

/// The seam for activity detection, independent of how activity is observed (ADR-0001).
/// Everything above this protocol — `ActivityStateStore`, `StatusBarEngine`, `StatusBarShell`
/// — depends only on these two members, never on a concrete adapter like
/// `PollingActivitySource`. Swapping in the event-driven `ControlModeActivitySource` (SPEC
/// §3.2, a later feature) is a new adapter, not a rendering-layer change.
public protocol ActivitySource: AnyObject, Sendable {
    /// Panes to watch, keyed by pane id, valued by session name (ADR-0004). Called on every
    /// discovery pass; implementations diff against their current set and attach/detach as
    /// needed. `PollingActivitySource` only needs the keys; adapters that attach per session
    /// (e.g. `ControlModeActivitySource`) need the values too.
    func setWatchedPanes(_ panes: [String: String])

    /// Fires when a pane produces output.
    var onOutput: ((_ paneId: String, _ at: Date) -> Void)? { get set }
}
