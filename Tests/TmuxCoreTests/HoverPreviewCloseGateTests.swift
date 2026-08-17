import Testing
@testable import TmuxCore

/// Exercises `HoverPreviewCloseGate.shouldStayOpen(_:)` — the pure truth table backing
/// TASK-034's "stay open while the field has focus even if the mouse has left" rule (feature
/// spec § Architecture). Split out of `HoverPreviewController` (AppKit-facing, not unit-
/// testable) for the same reason `HoverPopupPlacement` was split out of the same controller —
/// see that suite's own doc comment.
@Suite struct HoverPreviewCloseGateTests {
    @Test func staysOpenWhenBothMouseInsideAndFieldFocused() {
        let signal = HoverPreviewCloseGate.Signal(mouseInside: true, fieldFocused: true)
        #expect(HoverPreviewCloseGate.shouldStayOpen(signal) == true)
    }

    @Test func staysOpenWhenMouseInsideButFieldNotFocused() {
        let signal = HoverPreviewCloseGate.Signal(mouseInside: true, fieldFocused: false)
        #expect(HoverPreviewCloseGate.shouldStayOpen(signal) == true)
    }

    @Test func staysOpenWhenFieldFocusedButMouseOutside() {
        let signal = HoverPreviewCloseGate.Signal(mouseInside: false, fieldFocused: true)
        #expect(HoverPreviewCloseGate.shouldStayOpen(signal) == true)
    }

    @Test func closesWhenNeitherMouseInsideNorFieldFocused() {
        let signal = HoverPreviewCloseGate.Signal(mouseInside: false, fieldFocused: false)
        #expect(HoverPreviewCloseGate.shouldStayOpen(signal) == false)
    }
}
