import Foundation

/// Orchestrates a Preview Client's grouped-session setup/teardown (glossary "Preview
/// Client") over `TmuxGateway`'s one-shot `run(_:)` — pure sequencing, decoupled from the
/// actual long-lived attach process (AppKit/SwiftTerm boundary, TmuxerApp's
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
    /// tearing down must never un-zoom a state the user set themselves.
    public struct GroupSession: Sendable, Equatable {
        public let groupName: String
        public let zoomedByUs: Bool
    }

    public let gateway: any TmuxGateway

    public init(gateway: any TmuxGateway) {
        self.gateway = gateway
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
        let groupName = PreviewClientInvocation.groupSessionName(paneID: paneID)
        let windowIndex = try resolveWindowIndex(paneID: paneID)

        _ = try? gateway.run(PreviewClientInvocation.killGroupArguments(groupName: groupName))

        do {
            _ = try gateway.run(PreviewClientInvocation.createGroupArguments(paneID: paneID, groupName: groupName))
            _ = try gateway.run(PreviewClientInvocation.selectWindowArguments(groupName: groupName, windowIndex: windowIndex))
            _ = try gateway.run(PreviewClientInvocation.selectPaneArguments(paneID: paneID))
        } catch {
            _ = try? gateway.run(PreviewClientInvocation.killGroupArguments(groupName: groupName))
            throw error
        }

        return GroupSession(groupName: groupName, zoomedByUs: zoomIfNeeded(groupName: groupName))
    }

    /// Best-effort: a group session that was never created (prepare failed at step 1) has
    /// nothing to kill, and `kill-session` on a name that doesn't exist just fails harmlessly.
    /// Restores zoom first, while the group's window pointer can still resolve the target
    /// window — killing the session first would make `zoomedQueryArguments`/
    /// `toggleZoomArguments`'s `-t <groupName>` target unresolvable.
    public func teardownGroupSession(_ session: GroupSession) {
        if session.zoomedByUs {
            _ = try? gateway.run(PreviewClientInvocation.toggleZoomArguments(groupName: session.groupName))
        }
        _ = try? gateway.run(PreviewClientInvocation.killGroupArguments(groupName: session.groupName))
    }

    /// Zooms the group's current window unless it's already zoomed — returns whether *this*
    /// call did the zooming, so `teardownGroupSession` only ever undoes a zoom it caused
    /// itself. Never throws: a failed query or toggle just means the popup falls back to
    /// showing the whole tiled window, same as before this existed.
    private func zoomIfNeeded(groupName: String) -> Bool {
        guard let flag = try? gateway.run(PreviewClientInvocation.zoomedQueryArguments(groupName: groupName)),
              flag.trimmingCharacters(in: .whitespacesAndNewlines) != "1" else {
            return false
        }
        return (try? gateway.run(PreviewClientInvocation.toggleZoomArguments(groupName: groupName))) != nil
    }

    /// `list-panes -t <paneID>` resolves to the pane's *window* and can return one row per
    /// pane in it — pick the row whose `#{pane_id}` matches exactly rather than trust the
    /// first line (see `PreviewClientInvocation.paneLookupArguments`'s doc comment).
    private func resolveWindowIndex(paneID: String) throws -> Int {
        let output = try gateway.run(PreviewClientInvocation.paneLookupArguments(paneID: paneID))
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 2, fields[0] == paneID, let index = Int(fields[1]) {
                return index
            }
        }
        throw PaneNotFound(paneID: paneID)
    }
}
