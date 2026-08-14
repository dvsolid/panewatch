/// Expresses how an `AgentType`'s badge should render — a literal text glyph (Pi's `π`) or an
/// SF Symbol name (Claude Code's `sparkle`) — without `TmuxCore` needing to import AppKit.
/// Mirrors the existing `TileColor` -> `NSColor` split (`ActivityPhase.color`): the rendering
/// *decision* stays headlessly testable here in `TmuxCore`; the actual `NSImage`/`NSTextField`
/// content is resolved once, at the `TmuxerApp` boundary (`TileCardView`).
public enum BadgeGlyph: Sendable, Equatable {
    case text(String)
    case symbol(name: String)
}
