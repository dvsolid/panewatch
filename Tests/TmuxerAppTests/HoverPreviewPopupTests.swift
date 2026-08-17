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

    /// Direct regression coverage for the original bug (a clip view whose horizontal scroller
    /// was disabled couldn't be scrolled to reveal off-screen content), decoupled from the real
    /// `quickReplyChips` catalog's current width — after dropping "Continue"/"Stop" and
    /// tightening `chipSpacing`, the six-chip rail no longer overflows in practice, which would
    /// make an overflow-dependent test vacuous against the real catalog. This builds a document
    /// view wider than the rail directly, so the assertion stays meaningful even as the catalog
    /// changes: scrolling the clip view to the document's trailing edge must bring content
    /// starting past the rail's width into `documentVisibleRect`.
    @Test func scrollingRevealsContentPastTheVisibleRail() {
        let popup = HoverPreviewPopup()
        let railWidth = popup.chipScrollView.bounds.width
        let overflowMarker = NSView(frame: NSRect(x: railWidth + 20, y: 0, width: 10, height: 10))
        let wideDocument = NSView(frame: NSRect(x: 0, y: 0, width: railWidth + 40, height: popup.chipScrollView.bounds.height))
        wideDocument.addSubview(overflowMarker)
        popup.chipScrollView.documentView = wideDocument

        #expect(!popup.chipScrollView.documentVisibleRect.contains(overflowMarker.frame))

        let clipView = popup.chipScrollView.contentView
        let maxScrollX = max(0, wideDocument.frame.width - clipView.bounds.width)
        clipView.scroll(to: NSPoint(x: maxScrollX, y: 0))
        popup.chipScrollView.reflectScrolledClipView(clipView)

        #expect(popup.chipScrollView.documentVisibleRect.contains(overflowMarker.frame))
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
