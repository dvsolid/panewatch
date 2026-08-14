import Foundation

/// The Phase 1 `ActivitySource` adapter (ADR-0001, SPEC §3.1): samples each watched pane's
/// visible screen on `probeInterval` and hashes it, firing `onOutput` when consecutive hashes
/// differ. `PollingActivitySource`'s own scheduling is entirely internal — nothing above the
/// `ActivitySource` seam calls a probe/tick method, matching SPEC §3: "Nothing above this
/// layer may know which source is in use."
///
/// `@unchecked Sendable`, lock-protected like `ActivityStateStore` and `AgentDetector`'s
/// `DescendantWalkCache`, for the same reason: the internal `DispatchSourceTimer` fires
/// `probeOnce()` on its own private queue while `setWatchedPanes` and the `onOutput` setter may
/// be called from another task, so `watchedPaneIds`, `lastHash`, and `outputHandler` — the only
/// mutable stored state — are all read and written exclusively under `lock`. `gateway`, `clock`,
/// and `timer` are safe unguarded: `gateway`/`clock` are `let`-bound at `init` and never
/// reassigned, and `timer` is touched only once more, in `deinit`, after which no other access
/// is possible.
public final class PollingActivitySource: ActivitySource, @unchecked Sendable {
    private let gateway: any TmuxGateway
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var watchedPaneIds: Set<String> = []
    private var lastHash: [String: Int] = [:]
    private var outputHandler: ((String, Date) -> Void)?
    private let timer: DispatchSourceTimer

    public var onOutput: ((String, Date) -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return outputHandler
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            outputHandler = newValue
        }
    }

    public init(
        gateway: any TmuxGateway,
        probeInterval: TimeInterval = TmuxCore.defaultProbeInterval,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.gateway = gateway
        self.clock = clock

        // Owns its own schedule rather than being driven by a caller — SPEC §3: "Nothing above
        // this layer may know which source is in use," so nothing above the `ActivitySource`
        // seam ever needs to call a probe/tick method. `DispatchSourceTimer` (not
        // `Foundation.Timer`) on purpose: it fires independent of any `RunLoop`, so this stays
        // headlessly correct even though `TmuxCore` never runs the app's main run loop
        // (CLAUDE.md: that belongs to `TmuxerApp`).
        let queue = DispatchQueue(label: "PollingActivitySource.probe")
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + probeInterval, repeating: probeInterval)
        timer = source
        source.setEventHandler { [weak self] in self?.probeOnce() }
        source.resume()
    }

    deinit {
        // A resumed `DispatchSourceTimer` is kept alive by the system independent of Swift's
        // own reference count until cancelled — cancel before the last reference drops so the
        // timer stops firing here rather than outliving this instance.
        timer.cancel()
    }

    public func setWatchedPanes(_ paneIds: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        watchedPaneIds = paneIds
        // Drop cached hashes for panes no longer watched, so a pane that leaves and later
        // rejoins the watched set is treated as a fresh, un-diffed sample rather than
        // comparing against stale content from before it was dropped.
        for staleId in lastHash.keys where !paneIds.contains(staleId) {
            lastHash.removeValue(forKey: staleId)
        }
    }

    /// One probe pass across every currently-watched pane: capture, hash, compare against the
    /// previous sample, fire `onOutput` on change. Exactly one `capturePane` spawn per watched
    /// pane (this task's acceptance item 6) — never more, regardless of how many panes'
    /// content actually changed. A pane's first-ever sample never fires `onOutput`: there is no
    /// prior hash to differ from yet.
    func probeOnce() {
        let (paneIds, handler): (Set<String>, ((String, Date) -> Void)?) = {
            lock.lock()
            defer { lock.unlock() }
            return (watchedPaneIds, outputHandler)
        }()

        for paneId in paneIds {
            guard let output = try? gateway.capturePane(paneId) else { continue }
            let hash = output.hashValue

            let changed: Bool = {
                lock.lock()
                defer { lock.unlock() }
                let previous = lastHash[paneId]
                lastHash[paneId] = hash
                return previous != nil && previous != hash
            }()

            if changed {
                handler?(paneId, clock())
            }
        }
    }
}
