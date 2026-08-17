/// Pure argument-vector builder for Inline Reply's two-step `send-keys` write (TASK-032) — the
/// same role `SwitchInvocation` plays for Switch's tmux-side retargeting. ADR-0006: the Preview
/// Client's own render attach stays `-f read-only` and untouched; Inline Reply is a completely
/// separate one-shot write path, `literalTextArguments` then a distinct `enterArguments` call,
/// both via the existing `TmuxGateway.run(_:)`.
///
/// No validation here (e.g. empty `text`) — that's the caller's business:
/// `HoverPreviewController.performInlineReply` no-ops on empty/whitespace-only text before ever
/// reaching this module, rather than sending a bare `Enter` as a side effect.
///
/// `-t <paneId>` precedes `-l --`, never the reverse: tmux's own option parsing stops at `--`,
/// so a target flag placed after it becomes literal text instead of resolving a target — live-
/// verified against a throwaway tmux session (see this task's `## Implementation` notes) that
/// `send-keys -l -- -t <pane> "<text>"` silently sends nothing to the intended pane at all.
public enum InlineReplyInvocation {
    /// `send-keys -t <paneId> -l -- <text>` — the `-l` literal flag means `text` is never
    /// reinterpreted as a key name (e.g. the literal string `"Enter"`), and the `--` separator
    /// means a `text` starting with `-` is never parsed as a flag.
    public static func literalTextArguments(paneId: String, text: String) -> [String] {
        ["send-keys", "-t", paneId, "-l", "--", text]
    }

    /// `send-keys -t <paneId> Enter` — a separate call from `literalTextArguments`, per
    /// ADR-0006, never combined into one invocation.
    public static func enterArguments(paneId: String) -> [String] {
        ["send-keys", "-t", paneId, "Enter"]
    }
}
