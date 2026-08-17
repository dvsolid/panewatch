/// The single decision "should the Hover Preview Popup stay open," given mouse-inside and
/// Preview-Input-focus signals (TASK-034, feature spec § Architecture) — replaces
/// `HoverPreviewController`'s previous mouse-only close logic. Split out of that AppKit-facing
/// controller for the same reason `HoverPopupPlacement` was: adding a second signal directly
/// into the controller's several close call sites (`mouseExited`, `scheduleClose`/
/// `cancelClose`) risks the two staying in sync only by accident. Pure and headlessly
/// testable — see `HoverPreviewCloseGateTests`.
public enum HoverPreviewCloseGate {
    public struct Signal: Equatable, Sendable {
        public var mouseInside: Bool
        public var fieldFocused: Bool

        public init(mouseInside: Bool, fieldFocused: Bool) {
            self.mouseInside = mouseInside
            self.fieldFocused = fieldFocused
        }
    }

    /// `true` => popup must stay open (don't schedule/allow close). Stays open whenever either
    /// signal holds — the mouse being inside the Tile/popup, or the Preview Input field having
    /// focus (even with the mouse fully outside the popup's bounds).
    public static func shouldStayOpen(_ signal: Signal) -> Bool {
        signal.mouseInside || signal.fieldFocused
    }
}
