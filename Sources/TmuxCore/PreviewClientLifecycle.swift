import Foundation

/// Orchestrates a Preview Client's grouped-session setup/teardown (glossary "Preview
/// Client") over `TmuxGateway`'s one-shot `run(_:)` — pure sequencing, decoupled from the
/// actual long-lived attach process (AppKit/SwiftTerm boundary, PaneWatchApp's
/// `PreviewClient`) so the setup steps and their failure handling are fixture-testable
/// against a fake gateway rather than only manually verifiable. See
/// `PreviewClientInvocation`'s doc comment for the live-tmux findings that shaped this.
public struct PreviewClientLifecycle: Sendable {
    /// Thrown by `prepareGroupSession` when `paneID` no longer exists — `list-panes -t
    /// <paneID>` is the one call in the sequence that reliably fails for a dead pane (unlike
    /// `new-session -t <target>`, verified to silently phantom-create instead). The caller
    /// (`PreviewClient`) treats this the same as any other step's throw: show the "preview
    /// unavailable" state, never a blank/frozen view.
    public struct PaneNotFound: Error, Equatable {
        public let paneID: String
    }

    /// Returned by `prepareGroupSession` — `zoomedByUs` tells `teardownGroupSession` whether
    /// it, not the user, is responsible for un-zooming on the way out. Zoom is a window-level
    /// property shared with the source session (`PreviewClientInvocation.zoomedQueryArguments`'s
    /// doc comment), so leaving this false when the window came in already zoomed matters:
    /// tearing down must never un-zoom a state the user set themselves. Also carries `paneID`
    /// so `teardownGroupSession` can mute the same pane its own restoring un-zoom will repaint,
    /// without every caller having to pass it back in separately.
    public struct GroupSession: Sendable, Equatable {
        public let paneID: String
        public let groupName: String
        public let zoomedByUs: Bool
        /// `#{window_height}` of the real tmux window behind this group, captured at prepare
        /// time (before the attach spawns) — `-f ignore-size` (`PreviewClientInvocation
        /// .attachInvocation`'s doc comment) means tmux never shrinks that window to fit an
        /// undersized Preview Client, so a client with fewer rows than this number gets a
        /// viewport tmux positions around wherever the pane's cursor currently sits, not the
        /// window's true top or bottom. Verified live against a real zoomed Pi pane (window
        /// taller than the popup's default-font row budget): content tmux wrote at rows beyond
        /// the client's own row count never appeared at all — not merely a truncated bottom
        /// edge, the whole screen came back blank, because every line the source program
        /// painted landed on a row number the client's own buffer doesn't have. `PreviewClient`
        /// (PaneWatchApp) reads this before spawning the attach and shrinks its terminal's font
        /// until its own row count is at least this, so the client can always show the window's
        /// full height regardless of where the source program's cursor happens to rest.
        public let windowHeight: Int
    }

    /// How long a zoom toggle's own transient repaint is muted from `ActivityStateStore` —
    /// long enough that at least one full `PollingActivitySource` probe cycle is guaranteed to
    /// land inside the window rather than racing it (the two run on independent clocks), short
    /// enough that a real burst of agent output landing right as a hover starts or ends isn't
    /// swallowed for long. `TmuxCore.defaultProbeInterval` plus a fixed margin for scheduling
    /// jitter, not a multiple of it — the margin only needs to cover jitter, not a whole extra
    /// cycle.
    static let zoomActivityMuteWindow: TimeInterval = TmuxCore.defaultProbeInterval + 2

    public let gateway: any TmuxGateway
    private let activityMuter: (any ActivityMuter)?
    private let clock: @Sendable () -> Date

    public init(
        gateway: any TmuxGateway,
        activityMuter: (any ActivityMuter)? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.gateway = gateway
        self.activityMuter = activityMuter
        self.clock = clock
    }

    /// Runs every one-shot step that must succeed before the long-lived attach spawns, and
    /// returns the group session to attach to. Throws if the pane is gone or tmux itself
    /// errors at any step through step 5; never leaves a partially-created group session
    /// behind (see the `catch` below).
    ///
    /// 1. **Pane existence + window index** (`paneLookupArguments`) — must run first; see
    ///    `PaneNotFound`'s doc comment for why this, not `new-session`, is the reliable
    ///    existence check.
    /// 2. **Stale-leftover cleanup** (`killGroupArguments`, best-effort) — a previous preview
    ///    for the same pane that didn't tear down cleanly (e.g. app crash) would otherwise
    ///    collide with step 3's `-s <groupName>`.
    /// 3. **Create the grouped session** (`createGroupArguments`) — shares the pane's
    ///    windows but keeps its own independent current-window pointer; see
    ///    `PreviewClientInvocation`'s doc comment for why this replaces a direct pane-target
    ///    attach.
    /// 4. **Point the group at the target window** (`selectWindowArguments`, explicit
    ///    `<group>:<index>`) — see `PreviewClientInvocation`'s doc comment for why a bare
    ///    pane id here is unreliable.
    /// 5. **Select the pane within that window** (`selectPaneArguments`) — matches SPEC §4's
    ///    own select-window/select-pane pairing.
    /// 6. **Zoom the pane if the window isn't already zoomed** (`zoomIfNeeded`, best-effort,
    ///    never throws) — without this, an attached client shows the *whole window* tiled
    ///    (every sibling pane alongside the target one), not just the hovered pane. Best-effort
    ///    because a failure here should degrade to that tiled view rather than fail the whole
    ///    preview.
    public func prepareGroupSession(paneID: String) throws -> GroupSession {
        // Armed before any tmux command below runs, unconditionally — not just around the zoom
        // toggle further down. `PreviewClient` (PaneWatchApp) is about to attach its own read-only
        // client to the group session this function builds, and that's a second, independent
        // source of false activity: live-verified against a real tmux 3.6a server, a pane whose
        // foreground program has an active terminal mode (Claude Code enables the Kitty
        // keyboard protocol on start, `CSI > 1 u` / `CSI > 4;2 m`) gets that mode state replayed
        // as a genuine `%output` the moment *any* new session/client touches its window — not
        // only on the eventual client attach, but as early as `createGroupArguments`'s
        // `new-session -t <paneID> ...` a few lines down. A Pi pane sharing the exact same
        // window and sequence never produced this (confirmed live, same server, same moment):
        // Pi doesn't enable that protocol, so there's no mode state to replay. Muting at the end
        // of this function (an earlier version of this fix) left that `new-session` step's own
        // replay unmuted — live-verified: the very first hover after a mute-at-the-end build
        // still recorded real activity, with a *second*, later replay correctly suppressed —
        // proving the race was real, not hypothetical. Muting here, before anything runs, is
        // what closes it. Kept in `TmuxCore` rather than `PreviewClient` (PaneWatchApp) so this
        // stays fixture-testable.
        muteActivity(paneID: paneID)

        let groupName = PreviewClientInvocation.groupSessionName(paneID: paneID)
        let geometry = try resolveWindowGeometry(paneID: paneID)

        _ = try? gateway.run(PreviewClientInvocation.killGroupArguments(groupName: groupName))

        do {
            _ = try gateway.run(PreviewClientInvocation.createGroupArguments(paneID: paneID, groupName: groupName))
            _ = try gateway.run(PreviewClientInvocation.selectWindowArguments(groupName: groupName, windowIndex: geometry.windowIndex))
            _ = try gateway.run(PreviewClientInvocation.selectPaneArguments(paneID: paneID))
        } catch {
            _ = try? gateway.run(PreviewClientInvocation.killGroupArguments(groupName: groupName))
            throw error
        }

        let zoomedByUs = zoomIfNeeded(groupName: groupName, paneID: paneID)

        return GroupSession(
            paneID: paneID,
            groupName: groupName,
            zoomedByUs: zoomedByUs,
            windowHeight: geometry.windowHeight
        )
    }

    /// Best-effort: a group session that was never created (prepare failed at step 1) has
    /// nothing to kill, and `kill-session` on a name that doesn't exist just fails harmlessly.
    /// Restores zoom first, while the group's window pointer can still resolve the target
    /// window — killing the session first would make `zoomedQueryArguments`/
    /// `toggleZoomArguments`'s `-t <groupName>` target unresolvable.
    public func teardownGroupSession(_ session: GroupSession) {
        if session.zoomedByUs {
            _ = try? gateway.run(PreviewClientInvocation.toggleZoomArguments(groupName: session.groupName))
            muteActivity(paneID: session.paneID)
        }
        _ = try? gateway.run(PreviewClientInvocation.killGroupArguments(groupName: session.groupName))
    }

    /// Zooms the group's current window unless it's already zoomed — returns whether *this*
    /// call did the zooming, so `teardownGroupSession` only ever undoes a zoom it caused
    /// itself. Never throws: a failed query or toggle just means the popup falls back to
    /// showing the whole tiled window, same as before this existed.
    private func zoomIfNeeded(groupName: String, paneID: String) -> Bool {
        guard let flag = try? gateway.run(PreviewClientInvocation.zoomedQueryArguments(groupName: groupName)),
              flag.trimmingCharacters(in: .whitespacesAndNewlines) != "1" else {
            return false
        }
        guard (try? gateway.run(PreviewClientInvocation.toggleZoomArguments(groupName: groupName))) != nil else {
            return false
        }
        muteActivity(paneID: paneID)
        return true
    }

    /// Also called unconditionally from the top of `prepareGroupSession`, not just after a zoom
    /// toggle actually ran (in, at the end of `zoomIfNeeded`; out, in `teardownGroupSession`) —
    /// those two skip a query/toggle that failed or a window already zoomed, since neither
    /// changes what's on screen. See `ActivityStateStore.muteOutput(paneId:until:)`'s doc
    /// comment for why this mute exists.
    private func muteActivity(paneID: String) {
        activityMuter?.muteOutput(paneId: paneID, until: clock().addingTimeInterval(Self.zoomActivityMuteWindow))
    }

    private struct WindowGeometry {
        let windowIndex: Int
        let windowHeight: Int
    }

    /// `list-panes -t <paneID>` resolves to the pane's *window* and can return one row per
    /// pane in it — pick the row whose `#{pane_id}` matches exactly rather than trust the
    /// first line (see `PreviewClientInvocation.paneLookupArguments`'s doc comment). Both the
    /// window index and its height come from that same matching row, never a different one.
    private func resolveWindowGeometry(paneID: String) throws -> WindowGeometry {
        let output = try gateway.run(PreviewClientInvocation.paneLookupArguments(paneID: paneID))
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 3, fields[0] == paneID, let index = Int(fields[1]), let height = Int(fields[2]) {
                return WindowGeometry(windowIndex: index, windowHeight: height)
            }
        }
        throw PaneNotFound(paneID: paneID)
    }
}
