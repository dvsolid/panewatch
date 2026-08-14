import Foundation

/// Orchestrates discovery and publishes the Tile list for `StatusBarShell` to render.
///
/// One discovery pass, classified through `AgentDetector` (TASK-003), watched through
/// `ActivitySource` and phase-derived through `ActivityStateStore` (TASK-005), and mapped to
/// `TileState` — plain shells, ssh, and ngrok panes never reach the Tile list. No periodic
/// re-scan / topology reconciliation yet (TASK-006). Feature spec § Architecture leaves the
/// exact publishing shape TBD at execute time; a single throwing call is all this slice needs.
public struct StatusBarEngine: Sendable {
    private let discovery: PaneDiscovery
    private let detector: AgentDetector
    private let activityStateStore: ActivityStateStore
    private let activitySource: any ActivitySource

    /// `activitySource` has no default: like `discovery`, it is a real collaborator that talks
    /// to tmux (indirectly, via whatever `TmuxGateway` its adapter was built with), and
    /// `TmuxCore` never defaults those — only `StatusBarShell` (the composition root) does.
    /// See `AgentDetector`'s `discovery` parameter for the same discipline.
    public init(
        discovery: PaneDiscovery,
        detector: AgentDetector = AgentDetector(),
        activityStateStore: ActivityStateStore = ActivityStateStore(),
        activitySource: any ActivitySource
    ) {
        self.discovery = discovery
        self.detector = detector
        self.activityStateStore = activityStateStore
        self.activitySource = activitySource
        let store = activityStateStore
        activitySource.onOutput = { paneId, at in store.recordOutput(paneId: paneId, at: at) }
    }

    /// `now` defaults to the real clock; a test can pin it to make the resulting phases
    /// deterministic without waiting on wall-clock time.
    public func scanTiles(now: Date = Date()) throws -> [TileState] {
        let panes = detector.classify(try discovery.scan())
        activitySource.setWatchedPanes(Set(panes.map(\.id)))
        return panes.map { pane in
            TileState(pane: pane, phase: activityStateStore.phase(for: pane.id, now: now))
        }
    }
}
