import AppKit

/// A borderless, layer-backed `NSButton` that highlights the instant the pointer enters —
/// unlike stock bezel styles (`.inline`, `.rounded`, …), which only react on mouse-down, not
/// hover. Used for the Hover Preview Popup's Preview Input row: the Quick Reply chip rail and
/// the send button both want a flat "chip" look with real hover feedback, and drawing that as
/// a solid layer color gives full control over resting/hover fill and corner radius rather than
/// fighting a system bezel's own drawing.
final class HoverBackgroundButton: NSButton {
    var restingColor: NSColor = NSColor.white.withAlphaComponent(0.08) {
        didSet { updateBackgroundColor() }
    }
    var hoverColor: NSColor = NSColor.white.withAlphaComponent(0.18) {
        didSet { updateBackgroundColor() }
    }
    /// `bounds.height / 2` (pill) by default; the send button overrides this to a small fixed
    /// radius for a rounded-square look instead.
    var cornerRadius: CGFloat? {
        didSet { layer?.cornerRadius = cornerRadius ?? bounds.height / 2 }
    }

    private var isHovering = false {
        didSet { updateBackgroundColor() }
    }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        wantsLayer = true
        setButtonType(.momentaryChange)
        updateBackgroundColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = cornerRadius ?? bounds.height / 2
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        // `.activeAlways`, not `.activeInKeyWindow`: this popup is a `.nonactivatingPanel` that
        // opens on hover without becoming key (`becomesKeyOnlyIfNeeded`) — with `.activeInKeyWindow`
        // these buttons only started receiving mouseEntered/mouseExited once something else (the
        // reply field) made the window key first, leaving hover dead on a freshly opened popup.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1.0 : 0.4 }
    }

    private func updateBackgroundColor() {
        layer?.backgroundColor = (isHovering ? hoverColor : restingColor).cgColor
    }
}
