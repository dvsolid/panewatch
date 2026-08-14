/// Orchestrates discovery and publishes the Tile list for `StatusBarShell` to render.
///
/// Minimal for this slice (TASK-002): one discovery pass, mapped straight to `TileState`,
/// completely unfiltered — no classification (TASK-003) and no periodic re-scan / topology
/// reconciliation yet (TASK-006). Feature spec § Architecture leaves the exact publishing
/// shape TBD at execute time; a single throwing call is all this slice needs.
public struct StatusBarEngine: Sendable {
    private let discovery: PaneDiscovery

    public init(discovery: PaneDiscovery) {
        self.discovery = discovery
    }

    public func scanTiles() throws -> [TileState] {
        try discovery.scan().map(TileState.init)
    }
}
