import AppKit
import Testing
import TmuxCore
@testable import TmuxerApp

/// Local fake `TmuxGateway`, mirroring `TmuxCoreTests/PreviewClientLifecycleTests.swift`'s
/// `ScriptedTmuxGateway` — that one is `private` to its own file, so this suite needs its own
/// copy rather than reaching across module test targets for it.
private final class ScriptedTmuxGateway: TmuxGateway, @unchecked Sendable {
    struct CommandFailed: Error, Equatable { let arguments: [String] }

    private(set) var calls: [[String]] = []
    private var failing: Set<String> = []

    func listPanes() throws -> String { "" }
    func listClients() throws -> String { "" }
    func capturePane(_ paneId: String) throws -> String { "" }

    func run(_ arguments: [String]) throws -> String {
        calls.append(arguments)
        let key = arguments.joined(separator: " ")
        if failing.contains(key) {
            throw CommandFailed(arguments: arguments)
        }
        return ""
    }

    func fail(_ arguments: [String]) {
        failing.insert(arguments.joined(separator: " "))
    }
}

/// Whole-branch review fix for TASK-033 (Quick Reply chip rail overflow — the rail's
/// `NSScrollView` disabled horizontal scrolling entirely, clipping the last chip with no way to
/// reach it) and TASK-034 (the focus hook fired on first keystroke, not on focus, via
/// `controlTextDidBeginEditing`, letting the close-timer close the popup out from under a
/// click-then-hover-away reply with no typing).
@MainActor
@Suite struct HoverPreviewPopupTests {
    // MARK: - TASK-033: chip rail overflow

    /// The eight fixed Quick Reply chips at their natural (`sizeToFit`) widths are wider than
    /// `chipRailWidth` — this is the overflow the finding described, and every other assertion
    /// in this suite depends on it being real (a layout change that shrank the chips or widened
    /// the rail enough to fit them all would make the rest of this suite vacuous, so this is
    /// checked explicitly first).
    @Test func chipRailContentOverflowsTheVisibleRail() {
        let popup = HoverPreviewPopup()

        let documentWidth = popup.chipScrollView.documentView?.frame.width ?? 0
        let railWidth = popup.chipScrollView.bounds.width

        #expect(documentWidth > railWidth)
    }

    /// Before the fix, `hasHorizontalScroller = false` meant AppKit never installed a
    /// horizontal `NSScroller` on this scroll view at all — checking the scroller *instance*,
    /// not just the boolean flag, catches a regression where the flag is set but never actually
    /// takes effect (e.g. set after the scroll view is already laid out).
    @Test func chipRailHasAnInstalledHorizontalScroller() {
        let popup = HoverPreviewPopup()

        #expect(popup.chipScrollView.hasHorizontalScroller)
        #expect(popup.chipScrollView.horizontalScroller != nil)
    }

    /// The overlay style is required so the scroller doesn't consume layout space in the
    /// compact single-row footer (feature spec "Option A: single row").
    @Test func chipRailScrollerIsOverlayStyle() {
        let popup = HoverPreviewPopup()

        #expect(popup.chipScrollView.scrollerStyle == .overlay)
    }

    /// The concrete regression: with the rail's content overflowing (confirmed above), the last
    /// chip ("Stop", per `quickReplyChips`' fixed order) starts outside `documentVisibleRect` —
    /// clipped, matching the finding — but scrolling the clip view to the document's trailing
    /// edge brings it fully into view. Before the fix this last step was still mechanically
    /// possible via the clip view's own `scroll(to:)`, but with no scroller ever installed
    /// (previous assertion) there was no discoverable, user-drivable way to get there — this
    /// test exercises the same `NSClipView` scroll path a trackpad/scroll-wheel gesture would
    /// take, confirming reaching the last chip is possible end-to-end.
    @Test func scrollingRevealsTheLastChip() throws {
        let popup = HoverPreviewPopup()
        guard let documentView = popup.chipScrollView.documentView,
              let lastChip = documentView.subviews.last else {
            Issue.record("chip rail has no chips to scroll to")
            return
        }

        // Starting layout: the rail shows only its leading edge, so the last chip must not
        // already be fully visible (otherwise this test would prove nothing about scrolling).
        #expect(!popup.chipScrollView.documentVisibleRect.contains(lastChip.frame))

        let clipView = popup.chipScrollView.contentView
        let maxScrollX = max(0, documentView.frame.width - clipView.bounds.width)
        clipView.scroll(to: NSPoint(x: maxScrollX, y: 0))
        popup.chipScrollView.reflectScrolledClipView(clipView)

        #expect(popup.chipScrollView.documentVisibleRect.contains(lastChip.frame))
    }

    // MARK: - TASK-034: focus tracking via first-responder, not begin-editing

    /// `makeFirstResponder(_:)` is the seam the fix drives `onInlineReplyFieldFocusChanged`
    /// from. `HoverPreviewPopup()` builds an offscreen, never-ordered-front window — if
    /// `makeFirstResponder` can't succeed at all in that state, this assertion fails loudly
    /// (`try #require`) rather than silently passing without ever exercising the transition.
    @Test func makeFirstResponderIntoTheFieldReportsFocusGained() throws {
        let popup = HoverPreviewPopup()
        var reported: [Bool] = []
        popup.onInlineReplyFieldFocusChanged = { reported.append($0) }

        let succeeded = popup.makeFirstResponder(popup.inputField)

        try #require(succeeded, "makeFirstResponder(inputField) did not succeed — this suite can't observe the transition it's meant to test")
        #expect(reported == [true])
        #expect(popup.firstResponder === popup.inputField || popup.firstResponder === popup.inputField.currentEditor())
    }

    /// The bug this fix closes: a click that focuses the field but resigns before any typing
    /// must still report `false` on resign — under the old `controlTextDidBeginEditing`-based
    /// wiring this exact sequence (focus, no typing, resign) never fired anything, leaving
    /// `fieldFocused` stuck `true` in `HoverPreviewController` and never reporting the resign at
    /// all in the no-typing case. Here, resigning to `nil` (a click outside the field) must
    /// report a `false` after the `true`.
    @Test func resigningFirstResponderAfterFocusReportsFocusLost() throws {
        let popup = HoverPreviewPopup()
        var reported: [Bool] = []
        popup.onInlineReplyFieldFocusChanged = { reported.append($0) }

        let focused = popup.makeFirstResponder(popup.inputField)
        try #require(focused)
        let resigned = popup.makeFirstResponder(nil)

        try #require(resigned, "makeFirstResponder(nil) did not succeed — this suite can't observe the resign transition it's meant to test")
        #expect(reported == [true, false])
    }

    /// A first-responder change that isn't actually a transition for `inputField` (e.g.
    /// re-affirming `nil` when nothing was focused) must not re-report a signal that hasn't
    /// changed — the dedupe (`lastReportedFieldFocus`) this fix adds.
    @Test func repeatedNonTransitionsDoNotReReportTheSameSignal() {
        let popup = HoverPreviewPopup()
        var reported: [Bool] = []
        popup.onInlineReplyFieldFocusChanged = { reported.append($0) }

        _ = popup.makeFirstResponder(nil)
        _ = popup.makeFirstResponder(nil)

        #expect(reported.isEmpty)
    }

    // MARK: - Preview Input reply send failure handling

    /// The concrete bug: if the literal-text send throws, the old code sent `Enter` anyway —
    /// delivering a bare `Enter` keystroke to the pane with no text, which
    /// `InlineReplyInvocation`'s own doc comment says must never happen. After the fix, a
    /// failing literal-text send must leave the gateway having seen only that one call, never
    /// the `Enter` follow-up.
    @Test func sendInlineReplyNeverSendsEnterWhenLiteralTextSendFails() {
        let gateway = ScriptedTmuxGateway()
        let paneID = "%51"
        let literalArgs = InlineReplyInvocation.literalTextArguments(paneId: paneID, text: "hello")
        gateway.fail(literalArgs)

        HoverPreviewController.sendInlineReply(paneID: paneID, text: "hello", gateway: gateway)

        #expect(gateway.calls == [literalArgs])
    }

    /// The success path: both calls still run, in ADR-0006's required order (literal text,
    /// then a separate `Enter`).
    @Test func sendInlineReplySendsLiteralTextThenEnterOnSuccess() {
        let gateway = ScriptedTmuxGateway()
        let paneID = "%51"

        HoverPreviewController.sendInlineReply(paneID: paneID, text: "hello", gateway: gateway)

        #expect(gateway.calls == [
            InlineReplyInvocation.literalTextArguments(paneId: paneID, text: "hello"),
            InlineReplyInvocation.enterArguments(paneId: paneID)
        ])
    }
}
