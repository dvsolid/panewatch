import AppKit
import Testing
@testable import TmuxerApp

/// Exercises `HeaderView`'s pointer-tracking contract without a live window: `acceptsFirstMouse`
/// must opt the view into receiving clicks while the panel is never key (see the override's
/// doc comment), and a bare click (mouseDown -> mouseUp, no mouseDragged) must not fire
/// `onDragEnd` — that guard is only load-bearing once `acceptsFirstMouse` lets mouseDown reach
/// this view at all on the app's normal (non-activating, `.accessory`) path.
@Suite @MainActor struct HeaderViewTests {
    private func makeMouseEvent(type: NSEvent.EventType) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    @Test func acceptsFirstMouseIsTrue() {
        let header = HeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))

        #expect(header.acceptsFirstMouse(for: nil) == true)
    }

    @Test func plainClickWithoutDragDoesNotFireOnDragEnd() {
        let header = HeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        var dragEndFired = false
        header.onDragEnd = { dragEndFired = true }

        header.mouseDown(with: makeMouseEvent(type: .leftMouseDown))
        header.mouseUp(with: makeMouseEvent(type: .leftMouseUp))

        #expect(dragEndFired == false)
    }

    @Test func dragThenMouseUpFiresOnDragEnd() {
        let header = HeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        var dragEndFired = false
        header.onDragEnd = { dragEndFired = true }

        header.mouseDown(with: makeMouseEvent(type: .leftMouseDown))
        header.mouseDragged(with: makeMouseEvent(type: .leftMouseDragged))
        header.mouseUp(with: makeMouseEvent(type: .leftMouseUp))

        #expect(dragEndFired == true)
    }
}
