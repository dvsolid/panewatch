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

    public let gateway: any TmuxGateway

    public init(gateway: any TmuxGateway) {
        self.gateway = gateway
    }

    /// Runs every one-shot step that must succeed before the long-lived attach spawns, and
    /// returns the group session name to attach to. Throws if the pane is gone or tmux
    /// itself errors at any step; never leaves a partially-created group session behind (see
    /// the `catch` below).
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
    public func prepareGroupSession(paneID: String) throws -> String {
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

        return groupName
    }

    /// Best-effort: a group session that was never created (prepare failed at step 1) has
    /// nothing to kill, and `kill-session` on a name that doesn't exist just fails harmlessly.
    public func teardownGroupSession(_ groupName: String) {
        _ = try? gateway.run(PreviewClientInvocation.killGroupArguments(groupName: groupName))
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
