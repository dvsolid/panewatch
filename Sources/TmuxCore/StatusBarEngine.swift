import Foundation

/// Orchestrates discovery and publishes the Tile list for `StatusBarShell` to render.
///
/// Discovery, classified through `AgentDetector` (TASK-003), watched through `ActivitySource`
/// and phase-derived through `ActivityStateStore` (TASK-005), and mapped to `TileState` — plain
/// shells, ssh, and ngrok panes never reach the Tile list. Two entry points, one per cadence
/// (TASK-006): `reconcile(now:)` re-runs discovery on `discoveryInterval` and replaces the
/// retained pane set — the only call that spawns `list-panes -a`; `tiles(now:)` re-derives
/// Activity Phases for that retained set on `probeInterval`, with no new discovery spawn, so a
/// Tile's Fading color keeps advancing between discovery passes without tearing down and
/// recreating Tiles that haven't changed. Feature spec § Architecture leaves the exact
/// publishing shape TBD at execute time; two throwing/non-throwing calls are all this slice
/// needs — no actor, no `AsyncStream`.
public struct StatusBarEngine: Sendable {
    private let discovery: PaneDiscovery
    private let detector: AgentDetector
    private let activityStateStore: ActivityStateStore
    private let activitySource: any ActivitySource
    private let topology: KnownTopology

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
        self.topology = KnownTopology()
        let store = activityStateStore
        activitySource.onOutput = { paneId, at in store.recordOutput(paneId: paneId, at: at) }
    }

    /// Re-runs discovery, replaces the retained pane set with the fresh one (added panes join
    /// it, closed panes drop out, unchanged panes are simply present in both), and returns
    /// Tiles for it. Call this on `discoveryInterval` — it is the only method that spawns
    /// `list-panes -a`. `now` defaults to the real clock; a test can pin it to make the
    /// resulting phases deterministic without waiting on wall-clock time.
    public func reconcile(now: Date = Date()) throws -> [TileState] {
        let panes = detector.classify(try discovery.scan())

        // Every discovered pane gets seeded from tmux's own `window_activity` the first time
        // this store sees it — a no-op for a pane it already has a record for (from a prior
        // `onOutput` or a prior seed here). Unlike seeding from `now`, this is correct on the
        // very first `reconcile()` too: `window_activity` is tracked by the tmux server across
        // this app's whole lifetime, not reset by an app relaunch, so a pane that was active 10s
        // ago still reads as active immediately after a restart instead of a cold `.idle`.
        for pane in panes {
            activityStateStore.seedIfAbsent(paneId: pane.id, at: pane.windowActivityAt)
        }

        topology.replace(with: panes)
        activitySource.setWatchedPanes(Set(panes.map(\.id)))
        return tiles(now: now)
    }

    /// Re-derives each retained pane's Activity Phase for `now`, without a new discovery spawn.
    /// Safe to call every `probeInterval` tick between `reconcile` passes — a still-open pane's
    /// phase comes from `activityStateStore`, which is unaffected by how many times this runs.
    public func tiles(now: Date = Date()) -> [TileState] {
        topology.current.map { pane in
            TileState(pane: pane, phase: activityStateStore.phase(for: pane.id, now: now))
        }
    }
}

/// Retains the pane set found by the last `reconcile()` pass so `tiles(now:)` can re-derive
/// phases without a new discovery spawn. A class, not a struct: `StatusBarEngine` holds one
/// instance across repeated calls despite its own value semantics — the same reason
/// `ActivityStateStore` and `AgentDetector`'s `DescendantWalkCache` are class-backed.
/// Lock-protected for the same `Sendable`-safety reason as those two.
private final class KnownTopology: @unchecked Sendable {
    private var panes: [AgentPane] = []
    private let lock = NSLock()

    func replace(with newPanes: [AgentPane]) {
        lock.lock()
        defer { lock.unlock() }
        panes = newPanes
    }

    var current: [AgentPane] {
        lock.lock()
        defer { lock.unlock() }
        return panes
    }
}
