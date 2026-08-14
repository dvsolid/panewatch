/// Orchestrates discovery and publishes the Tile list for `StatusBarShell` to render.
///
/// One discovery pass, classified through `AgentDetector` (TASK-003) and mapped to
/// `TileState` — plain shells, ssh, and ngrok panes never reach the Tile list. No periodic
/// re-scan / topology reconciliation yet (TASK-006). Feature spec § Architecture leaves the
/// exact publishing shape TBD at execute time; a single throwing call is all this slice needs.
public struct StatusBarEngine: Sendable {
    private let discovery: PaneDiscovery
    private let detector: AgentDetector

    public init(discovery: PaneDiscovery, detector: AgentDetector = AgentDetector()) {
        self.discovery = discovery
        self.detector = detector
    }

    public func scanTiles() throws -> [TileState] {
        detector.classify(try discovery.scan()).map(TileState.init)
    }
}
