import Foundation

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

    /// SPEC.md §1 Timing table — single source of truth for the four-phase model's defaults,
    /// shared by `TmuxCore` (`ActivityStateStore`, `PollingActivitySource`) and `TmuxerApp`
    /// (the render-refresh timer), so the two layers can't drift apart on what "default" means.
    public static let defaultProbeInterval: TimeInterval = 5
    public static let defaultBlinkWindow: TimeInterval = 10
    public static let defaultReadyWindow: TimeInterval = 90
    public static let defaultFadeWindow: TimeInterval = 3600

    /// SPEC §2: "Re-scan every `discoveryInterval` (30s) and reconcile against cached state by
    /// `pane_id`." Deliberately slower than `defaultProbeInterval` — `list-panes -a` is a
    /// separate subprocess spawn from the per-pane `capturePane` polling, and new/closed
    /// sessions don't need probe-cadence responsiveness.
    public static let defaultDiscoveryInterval: TimeInterval = 30
}
