import Testing
@testable import TmuxCore

/// Covers `InlineReplyInvocation`'s pure argument-vector builders — Inline Reply's two-step
/// `send-keys` write (TASK-032): the literal-text call, then a separate `Enter`, both targeting
/// the pane's `pane_id` (ADR-0006). Mirrors `SwitchInvocationTests`' discipline: assert on the
/// exact vector without spawning a process. Argument order (`-t <pane>` before `-l --`) was
/// live-verified against a throwaway tmux session (this task's `## Implementation` notes) —
/// putting the target flag after `--` sends it as literal text instead of resolving a target,
/// which silently drops the write into whatever pane the (nonexistent, in this app) attached
/// client currently has active.
@Suite struct InlineReplyInvocationTests {
    /// `-l` (literal flag) plus `--` (end-of-options separator) means `text` is never
    /// reinterpreted as a key name or a flag, no matter what it contains.
    @Test func literalTextArgumentsTargetsThePaneAndSendsTextLiterally() {
        #expect(InlineReplyInvocation.literalTextArguments(paneId: "%51", text: "yes") == [
            "send-keys", "-t", "%51", "-l", "--", "yes"
        ])
    }

    /// The exact bug class ADR-0006 exists to prevent: without `-l`, tmux would try to resolve
    /// "Enter" as a key name and press it instead of typing the four literal characters.
    @Test func literalTextArgumentsKeepsAKeyNameCollisionAsLiteralText() {
        #expect(InlineReplyInvocation.literalTextArguments(paneId: "%51", text: "Enter") == [
            "send-keys", "-t", "%51", "-l", "--", "Enter"
        ])
    }

    /// Without the `--` separator, tmux's own getopt-style parsing would treat `-rf` as a flag
    /// to `send-keys` rather than the pane's literal text.
    @Test func literalTextArgumentsKeepsLeadingDashTextFromBeingParsedAsAFlag() {
        #expect(InlineReplyInvocation.literalTextArguments(paneId: "%51", text: "-rf") == [
            "send-keys", "-t", "%51", "-l", "--", "-rf"
        ])
    }

    /// A separate call from `literalTextArguments` (ADR-0006: "followed by a separate `tmux
    /// send-keys Enter`") — never combined into one invocation, so the literal text can never
    /// itself be misread as carrying a key name.
    @Test func enterArgumentsBuildsASeparateTargetedSendKeysEnterCall() {
        #expect(InlineReplyInvocation.enterArguments(paneId: "%51") == ["send-keys", "-t", "%51", "Enter"])
    }
}
