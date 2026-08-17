/// One of four states a Tile can be in, derived from `idleDuration` alone (SPEC §1). See
/// feature spec § Architecture, `ActivityStateStore`.
///
/// `fading`'s `colorFraction` is `0` at `readyWindow` (still green) and approaches `1` just
/// below `fadeWindow` (nearly grey) — `.idle` picks up exactly where a fraction of `1` would
/// leave off, so the two cases must render identically at that boundary (see `ActivityPhase.color`).
public enum ActivityPhase: Sendable, Equatable {
    case blinking
    case ready
    case fading(colorFraction: Double)
    case idle
}

/// Plain RGBA — no `NSColor` — so the color mapping stays in `TmuxCore` and is unit-testable
/// headlessly (CLAUDE.md: `TmuxCore` must stay free of AppKit). `PaneWatchApp` converts this to
/// `NSColor` at the render boundary.
public struct TileColor: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Linear per-channel interpolation. `alpha` is fixed at `1.0` on both endpoints this
    /// module uses it for, so the result stays fully opaque throughout — SPEC §1: "Opacity
    /// never drops below 100%, at any phase, forever," the explicit reversal of an earlier
    /// 20%-opacity-floor design.
    static func interpolate(from start: TileColor, to end: TileColor, fraction: Double) -> TileColor {
        let clamped = min(max(fraction, 0.0), 1.0)
        func lerp(_ a: Double, _ b: Double) -> Double { a + (b - a) * clamped }
        return TileColor(
            red: lerp(start.red, end.red),
            green: lerp(start.green, end.green),
            blue: lerp(start.blue, end.blue),
            alpha: lerp(start.alpha, end.alpha)
        )
    }
}

extension ActivityPhase {
    private static let blinkingOrange = TileColor(red: 1.0, green: 0.55, blue: 0.0, alpha: 1.0)
    private static let lightGreen = TileColor(red: 0.30, green: 0.78, blue: 0.30, alpha: 1.0)
    private static let grey = TileColor(red: 0.55, green: 0.55, blue: 0.55, alpha: 1.0)

    /// SPEC §1's Item Card table, as plain RGBA. `.ready` and `.fading(colorFraction: 0)` share
    /// `lightGreen` exactly, and `.fading(colorFraction: 1)` (approached, never reached — see
    /// `ActivityStateStore.phase`) shares `grey` exactly with `.idle`, so a Tile crossing a
    /// phase boundary never jumps color.
    public var color: TileColor {
        switch self {
        case .blinking: return Self.blinkingOrange
        case .ready: return Self.lightGreen
        case .fading(let colorFraction): return TileColor.interpolate(from: Self.lightGreen, to: Self.grey, fraction: colorFraction)
        case .idle: return Self.grey
        }
    }
}
