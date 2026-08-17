import AppKit
import Testing
@testable import TmuxerApp

/// Exercises `PreviewClient.sizeTerminal(toWindowRows:)` against the real SwiftTerm geometry
/// chain (`terminalView.frame =` → `processSizeChange(newSize:)` → `terminal.cols`/`.rows`) —
/// the fix for the bug where a Pi pane's zoomed window (real live measurement: 240x53) was
/// taller than the popup's row budget, and `-f ignore-size` left the Preview Client showing a
/// blank viewport because every row the source program painted landed past the client's own
/// row count.
///
/// This method replaced an earlier version (`fitFont(toWindowRows:)`) that shrank the
/// terminal's *font* to guarantee full coverage. Live user feedback on that real 53-row window
/// found the result close to unreadable, and inconsistent from preview to preview since each
/// window needed a different amount of shrinking. This version keeps the font fixed always and
/// grows the terminal view's *frame* past the popup's visible box instead, relying on
/// `HoverPreviewPopup.innerContent`'s clipping (`masksToBounds`) to hide the overflow — chosen
/// to grow upward from a fixed `y = 0` specifically because SwiftTerm draws the newest content
/// (the prompt) near the bottom of its own frame in AppKit's unflipped coordinate system, so
/// clipping the overflow at the top keeps the bottom — the part a live glance actually needs —
/// always in view, on request from the user who hit the unreadable-font version live.
///
/// `HoverPreviewController.startPreview` sets `client.terminalView`'s frame (via
/// `HoverPreviewPopup.showTerminal`, which assigns `innerContent.bounds`) *before* calling
/// `client.start(paneID:)`, so by the time `sizeTerminal` would run in production the view
/// already has a non-zero frame. That ordering is the one assumption this whole fix rests on and
/// this session has no way to confirm by actually hovering a Tile (no native-GUI-automation tool
/// available) — so this test reproduces the same non-zero-frame-before-resize sequence directly
/// against `PreviewClient.terminalView`, without spawning tmux at all, to verify
/// `processSizeChange(newSize:)`'s frame-based resize really does fire under that exact ordering.
///
/// Row/col counts below are read from the client under test rather than hardcoded: `makeTerminalFont()`
/// (`PreviewClient.swift`) falls back to the system monospaced font when its preferred Nerd Font
/// isn't installed, and the two have different cell metrics — a literal expected row count would
/// make this suite pass or fail depending on which fonts happen to be installed on whatever
/// machine runs it, rather than on the behavior actually under test.
@MainActor
@Suite struct PreviewClientSizeTerminalTests {
    /// Mirrors `HoverPreviewPopup.init`'s `innerContent` math: `HoverPopupPlacement.size`
    /// (760x620) minus `HoverPreviewPopup.contentInset` (10) on every edge.
    private static let innerContentBounds = CGRect(x: 0, y: 0, width: 740, height: 600)

    private func makeClientWithPopupSizedFrame() -> PreviewClient {
        let client = PreviewClient()
        // Reproduces `HoverPreviewPopup.showTerminal(_:)`'s frame assignment, which always
        // runs before `PreviewClient.start(paneID:)` in `HoverPreviewController.startPreview`.
        client.terminalView.frame = Self.innerContentBounds
        return client
    }

    /// Sanity check that the popup's fixed frame produces *some* real row budget at whichever
    /// font actually resolved (preferred Nerd Font or its system-font fallback) — every other
    /// test below depends on this being a genuine positive number to build its window sizes
    /// from.
    @Test func fixedFrameComputesAPositiveRowCount() {
        let client = makeClientWithPopupSizedFrame()

        #expect(client.terminalView.terminal.rows > 0)
    }

    /// A window that already fits inside the row budget must not touch the frame at all — only
    /// an undersized client should ever grow past the popup's visible box.
    @Test func sizeTerminalLeavesTheFrameAloneWhenTheWindowAlreadyFits() {
        let client = makeClientWithPopupSizedFrame()
        let originalFrame = client.terminalView.frame
        let baselineRows = client.terminalView.terminal.rows

        client.sizeTerminal(toWindowRows: max(1, baselineRows - 5))

        #expect(client.terminalView.frame == originalFrame)
    }

    /// The font must never change — that's the whole point of this fix over the version it
    /// replaced (its own doc comment above has the live user feedback that motivated dropping
    /// font-shrinking entirely). Every preview reads at the same size.
    @Test func sizeTerminalNeverChangesTheFont() {
        let client = makeClientWithPopupSizedFrame()
        let defaultPointSize = client.terminalView.font.pointSize
        let baselineRows = client.terminalView.terminal.rows

        client.sizeTerminal(toWindowRows: baselineRows * 10)

        #expect(client.terminalView.font.pointSize == defaultPointSize)
    }

    /// The bug's shape, reproduced relative to whatever row budget the resolved font actually
    /// gives: a window taller than the popup's fixed frame fits. Without the fix, tmux's
    /// `ignore-size` cursor-anchored viewport left this Preview Client showing a blank screen
    /// (verified live, against the real 240x53 Pi case) because the source pane's content was
    /// painted at rows past the client's own row count. After the fix, the terminal's own row
    /// count must cover the whole window — achieved by growing the frame, not shrinking the
    /// font — so no row the source program paints can land outside the client's buffer.
    @Test func sizeTerminalGrowsTheFrameSoTerminalRowsCoverAnOversizedWindow() {
        let client = makeClientWithPopupSizedFrame()
        let originalHeight = client.terminalView.frame.height
        let targetRows = client.terminalView.terminal.rows + 20

        client.sizeTerminal(toWindowRows: targetRows)

        #expect(client.terminalView.terminal.rows >= targetRows)
        #expect(client.terminalView.frame.height > originalHeight)
        #expect(client.terminalView.frame.width == Self.innerContentBounds.width)
    }

    /// The grown frame must keep its origin at `(0, 0)` within `innerContent` — SwiftTerm draws
    /// the newest content (the prompt) near the bottom of the view's own bounds in AppKit's
    /// unflipped coordinate system, so a fixed `y = 0` origin combined with `innerContent`
    /// clipping the now-taller view keeps the *bottom* of the real window in view (what the
    /// user asked for) rather than shifting the visible slice somewhere else.
    @Test func sizeTerminalKeepsTheOriginAtZeroSoTheBottomStaysInView() {
        let client = makeClientWithPopupSizedFrame()
        let targetRows = client.terminalView.terminal.rows + 20

        client.sizeTerminal(toWindowRows: targetRows)

        #expect(client.terminalView.frame.origin == .zero)
    }

    /// A pathologically tall window (far more rows than even a large grown frame needs) must
    /// still converge without looping forever — the frame-height scaling is exact modulo
    /// floor-rounding (unlike the font-metric case this replaced), so this should converge on
    /// the very first candidate, but the retry loop is still exercised end-to-end here.
    @Test func sizeTerminalConvergesForAPathologicallyTallWindow() {
        let client = makeClientWithPopupSizedFrame()
        let targetRows = client.terminalView.terminal.rows * 20

        client.sizeTerminal(toWindowRows: targetRows)

        #expect(client.terminalView.terminal.rows >= targetRows)
    }

    // MARK: - The permanent, non-functional scroller SwiftTerm installs

    /// Mirrors `HoverPreviewPopup.showTerminal(_:)`: the terminal view is added to a superview
    /// (`innerContent`) and given its bounds. Deliberately does *not* force a layout pass:
    /// production sizes the pty (`sizeTerminal(toWindowRows:)` → `startProcess`) before any
    /// layout runs, so the tests below must pin `viewDidMoveToSuperview` — the earlier of
    /// `ReadOnlyLocalProcessTerminalView`'s two hide hooks — rather than passing on `layout()`
    /// alone (confirmed by disabling each hook in turn).
    private func makeClientInstalledInAContainer() -> PreviewClient {
        let client = PreviewClient()
        let container = NSView(frame: Self.innerContentBounds)
        container.addSubview(client.terminalView)
        client.terminalView.frame = container.bounds
        return client
    }

    /// The user-visible bug: SwiftTerm's `TerminalView` unconditionally installs an `NSScroller`
    /// pinned down its full trailing edge, and since no `NSScrollView` manages it, nothing ever
    /// hides it — it drew a permanent light slot the height of the preview that scrolled nothing
    /// (`scroller.isEnabled = false`). Falsifiable in exactly that way: drop
    /// `ReadOnlyLocalProcessTerminalView`'s hide and a visible scroller reappears here.
    @Test func theTerminalViewShowsNoScroller() {
        let client = makeClientInstalledInAContainer()

        let visibleScrollers = client.terminalView.subviews.compactMap { $0 as? NSScroller }.filter { !$0.isHidden }

        #expect(visibleScrollers.isEmpty)
    }

    /// It must be *hidden*, not removed: SwiftTerm's own `reservedScrollerWidth` reads
    /// `scroller?.isHidden == true ? 0 : scrollerWidth`, so `isHidden` is what hands the reserved
    /// gutter back to the terminal — detaching the view would leave `isHidden == false`, keep the
    /// width reserved, and break the constraints SwiftTerm activated against it. This also proves
    /// the test above isn't passing vacuously against a view tree that never had a scroller.
    @Test func theScrollerIsHiddenRatherThanRemovedFromTheViewTree() throws {
        let client = makeClientInstalledInAContainer()

        let scroller = try #require(
            client.terminalView.subviews.compactMap { $0 as? NSScroller }.first,
            "SwiftTerm no longer installs an NSScroller — the hide in ReadOnlyLocalProcessTerminalView is now dead code"
        )

        #expect(scroller.isHidden)
    }

    /// Calling with a window that's not actually taller than what's already fitted must be a
    /// no-op, not a crash from dividing by a stale/zero row count.
    @Test func sizeTerminalIsANoOpWhenWindowRowsIsNotPositive() {
        let client = makeClientWithPopupSizedFrame()
        let originalFrame = client.terminalView.frame

        client.sizeTerminal(toWindowRows: 0)

        #expect(client.terminalView.frame == originalFrame)
    }
}
