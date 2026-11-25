import Foundation

/// The single decision "what should the floating panel do now" given what AppKit believes and
/// what the window server reports (TASK-040). Pure and headlessly testable — the AppKit
/// rebuild and the `CGWindowListCopyWindowInfo` query live in `PaneWatchApp`; see
/// `PanelStrandingPolicyTests`.
public enum PanelStrandingPolicy {
    /// How long a panel must have been shown before an absent window-server on-screen flag is
    /// believed. The flag lags `orderFrontRegardless()` (measured: nil synchronously after the
    /// order call, 1 by the next main-queue turn), so a reading inside this window is not
    /// evidence of anything.
    public static let settleInterval: TimeInterval = 0.3

    public enum Trigger: Equatable, Sendable {
        /// The user clicked the Menu Bar Icon: the caller always needs a show/hide/heal answer.
        case click
        /// The delayed re-check scheduled after a show: only ever heals — a healthy panel must
        /// be left untouched, never hidden.
        case settleCheck
    }

    public enum Action: Equatable, Sendable {
        case show
        case hide
        /// Replace the panel with a freshly created one and show it.
        case heal
        /// Stranded again after this attempt already healed once — stop rather than loop.
        case giveUp
        /// Nothing to do (`settleCheck` only).
        case none
    }

    public struct Input: Equatable, Sendable {
        /// AppKit's `isVisible`.
        public var appKitVisible: Bool
        /// The window server's `kCGWindowIsOnscreen` for the panel's window; `nil` when the
        /// flag (or the whole window entry) is absent.
        public var windowServerOnScreen: Bool?
        public var timeSinceShown: TimeInterval
        /// A heal already ran for this show attempt.
        public var alreadyHealed: Bool

        public init(
            appKitVisible: Bool,
            windowServerOnScreen: Bool?,
            timeSinceShown: TimeInterval,
            alreadyHealed: Bool
        ) {
            self.appKitVisible = appKitVisible
            self.windowServerOnScreen = windowServerOnScreen
            self.timeSinceShown = timeSinceShown
            self.alreadyHealed = alreadyHealed
        }

        /// AppKit says shown, it has been shown long enough for the window server to have
        /// caught up, and the window server still does not report it on screen.
        var isStranded: Bool {
            appKitVisible
                && timeSinceShown >= PanelStrandingPolicy.settleInterval
                && windowServerOnScreen != true
        }
    }

    public static func decide(_ trigger: Trigger, _ input: Input) -> Action {
        guard input.appKitVisible else {
            return trigger == .click ? .show : .none
        }
        if input.isStranded {
            return input.alreadyHealed ? .giveUp : .heal
        }
        return trigger == .click ? .hide : .none
    }
}
