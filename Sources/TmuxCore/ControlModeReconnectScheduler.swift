import Foundation

/// Injectable delay seam for `ControlModeActivitySource`'s reconnect logic (TASK-027): the one
/// place it asks "run this later" rather than sleeping or spinning. Two distinct uses share this
/// single seam rather than getting one each:
///
/// 1. Batching simultaneous `onTerminate` firings (distinguishing "one session's client died,
///    others still alive" from "the whole pool died at once, e.g. tmux server exit") — scheduled
///    with `delay: 0`, i.e. "run once the current synchronous burst of terminations has settled,"
///    not a real elapsed-time wait.
/// 2. Pacing retries after a failed reconnect attempt with backoff, so a launcher that keeps
///    failing (tmux still down) never turns into a tight retry loop.
///
/// Tests substitute a fake that records scheduled delays and fires them under explicit test
/// control instead of waiting on a real clock — mirrors `TmuxGateway`/`ControlModeProcessLauncher`
/// being fakeable seams for the same reason (no real subprocess/timing dependency in tests).
public protocol ControlModeReconnectScheduler: Sendable {
    /// Runs `action` after approximately `delay` seconds have elapsed. `delay` may be `0`
    /// (see use 1 above) — implementations must still defer past the caller's current
    /// synchronous execution, never invoke `action` inline.
    func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void)
}

/// The live adapter: hands `action` to a private serial dispatch queue after `delay`. A private
/// queue (not `DispatchQueue.global()`) so scheduled reconnect work never contends with, or gets
/// starved by, unrelated global-queue work.
public struct DispatchControlModeReconnectScheduler: ControlModeReconnectScheduler {
    private let queue = DispatchQueue(label: "ControlModeActivitySource.reconnect")

    public init() {}

    public func schedule(after delay: TimeInterval, _ action: @escaping @Sendable () -> Void) {
        queue.asyncAfter(deadline: .now() + delay, execute: action)
    }
}
