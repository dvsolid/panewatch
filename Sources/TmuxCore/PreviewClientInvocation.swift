import Foundation

/// Pure argument-vector builders for the tmux commands backing a Preview Client's
/// grouped-session lifecycle (glossary "Preview Client") — split out of
/// `PreviewClientLifecycle`'s sequencing logic the same way `ProcessTmuxGateway`'s
/// `listPanesInvocation`/`capturePaneInvocation` are split out of `listPanes()`/
/// `capturePane(_:)`, so a test can assert on the exact vector without spawning a process.
///
/// **Why a grouped session, not a direct pane-targeted attach:** TASK-015 was originally
/// specified as `tmux attach -r -f read-only,ignore-size -t <pane_id>`. Verified live
/// against tmux 3.6a that this retargets the pane's *source session's* shared
/// current-window pointer on every attach — `#{window_index}` was observed moving the
/// instant a pane-targeted client attached, reproduced both with and without a real client
/// already attached to that source session. That is the same "attach always creates an
/// additional client... leaving the user with two clients fighting over the same session"
/// hazard SPEC.md §4 already documents for Switch, just not previously connected to this
/// attach call. A **grouped session** — `new-session -t <pane_id> -d -s <group-name>` —
/// shares the pane's windows but keeps its own independent current-window pointer, so
/// pointing *that* pointer at the target window (`selectWindowArguments`) and attaching
/// read-only to the group (`attachInvocation`) never touches the source session at all.
///
/// **Why `selectWindowArguments` takes an explicit index, not a bare pane id:** also
/// verified live that `select-window -t <pane_id>` (no session prefix) resolves against
/// whatever tmux considers the "current session" when the command runs with no attached
/// client context of its own — reliable when the source session has no client attached,
/// but silently a no-op (landing on neither the source nor the freshly created group) once
/// the source session already has one, which is the realistic production case. Resolving
/// the window index up front (`paneLookupArguments`) and targeting `<group>:<index>`
/// explicitly removes the ambiguity.
///
/// **Why a separate pane-existence check is required at all:** verified live that `tmux
/// new-session -t <target>` does **not** fail for a target that doesn't resolve to any
/// pane/session — it silently creates a phantom *ungrouped* session instead (its
/// `#{session_group}` even echoes back the literal, unresolved target string). `list-panes
/// -t <pane_id>` is the call that reliably fails for a dead pane (`can't find pane: ...`,
/// exit 1), which is why `PreviewClientLifecycle.prepareGroupSession` runs
/// `paneLookupArguments` first, before ever creating anything.
public enum PreviewClientInvocation {
    /// Deterministic per-pane group-session name, so a leftover session from a previous
    /// run that didn't tear down cleanly (e.g. an app crash mid-preview) can be recognized
    /// and cleared before reuse rather than colliding with `-s <group-name>` on the next
    /// hover of the same pane. Strips the pane id's leading `%` — tmux session names don't
    /// need to carry the sigil.
    public static func groupSessionName(paneID: String) -> String {
        "tmuxer-preview-\(paneID.dropFirst())"
    }

    /// Resolves whether `paneID` still exists and, if so, which window holds it. `-t
    /// <paneID>` for `list-panes` resolves to the pane's *window*, listing every pane in it
    /// (verified live: a window with a split returns multiple rows for one `-t` target) —
    /// the format carries `#{pane_id}` alongside `#{window_index}` so the caller can pick
    /// the exact matching row rather than trust the first line.
    public static func paneLookupArguments(paneID: String) -> [String] {
        ["list-panes", "-t", paneID, "-F", "#{pane_id} #{window_index}"]
    }

    public static func killGroupArguments(groupName: String) -> [String] {
        ["kill-session", "-t", groupName]
    }

    /// `-t <paneID>`, not a session name — tmux resolves a pane id to its owning session for
    /// grouping purposes on its own, so pane_id remains the only pane-identifying input this
    /// whole flow needs (SPEC §3.4).
    public static func createGroupArguments(paneID: String, groupName: String) -> [String] {
        ["new-session", "-t", paneID, "-d", "-s", groupName]
    }

    /// Explicit `<groupName>:<windowIndex>` target — see this type's doc comment for why a
    /// bare pane id is unreliable here.
    public static func selectWindowArguments(groupName: String, windowIndex: Int) -> [String] {
        ["select-window", "-t", "\(groupName):\(windowIndex)"]
    }

    public static func selectPaneArguments(paneID: String) -> [String] {
        ["select-pane", "-t", paneID]
    }

    /// The one vector handed directly to `LocalProcessTerminalView.startProcess(executable:
    /// args:)` outside the `TmuxGateway` seam (TmuxerApp's `PreviewClient`) — carries
    /// `tmuxPath` so a test can assert the executable slot is never bare `tmux` (CLAUDE.md),
    /// the same reason `ProcessTmuxGateway.capturePaneInvocation` does. `-r` plus `-f
    /// read-only,ignore-size` matches the flags SPEC §3.2 already validated for monitoring
    /// clients; targets the *group* session, never the pane (see this type's doc comment).
    public static func attachInvocation(
        tmuxPath: String,
        groupName: String
    ) -> (executable: String, arguments: [String]) {
        (tmuxPath, ["attach", "-r", "-f", "read-only,ignore-size", "-t", groupName])
    }
}
