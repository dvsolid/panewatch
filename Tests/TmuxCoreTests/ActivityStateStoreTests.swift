import Foundation
import Testing
@testable import TmuxCore

/// Fixed reference instant so every test computes `idleDuration` from an exact, readable
/// offset rather than wall-clock `Date()` — SPEC's four-phase model and this task's Test seam
/// both require boundary exactness, which a live clock can't give a test.
private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

/// Acceptance item 1: a pane that just produced output shows blinking orange. Exercised at
/// the declared seam — `ActivityStateStore.phase(for:now:)` — as a pure function of a fixed
/// `idleDuration`, no timer or subprocess involved (Test seam).
@Test func recentOutputShowsBlinkingOrange() {
    let store = ActivityStateStore()
    store.recordOutput(paneId: "%1", at: referenceDate)

    let phase = store.phase(for: "%1", now: referenceDate.addingTimeInterval(5))

    #expect(phase == .blinking)
    // Falsifiable against the actual defect class SPEC calls out (§1): color, not just phase
    // label, is asserted — a mapping bug (e.g. `.blinking` rendered as some other hue) would
    // pass a phase-only check but fail this one.
    let color = phase.color
    #expect(color.red > color.green)
    #expect(color.red > color.blue)
    #expect(color.alpha == 1.0)
}

/// Acceptance item 2: a Tile idle between `blinkWindow` and `readyWindow` shows steady light
/// green. Exact-boundary case at `blinkWindow` per this task's Test seam — `idleDuration ==
/// blinkWindow` must already read `.ready`, not `.blinking`; `ActivityStateStore.phase`'s
/// switch uses `..<blinkWindow` (half-open), so this pins the boundary belongs to `.ready`.
@Test func idleBetweenBlinkAndReadyWindowShowsSteadyLightGreen() {
    let store = ActivityStateStore(blinkWindow: 10, readyWindow: 90, fadeWindow: 3600)
    store.recordOutput(paneId: "%1", at: referenceDate)

    let atBlinkWindow = store.phase(for: "%1", now: referenceDate.addingTimeInterval(10))
    let midReadyWindow = store.phase(for: "%1", now: referenceDate.addingTimeInterval(50))

    #expect(atBlinkWindow == .ready)
    #expect(midReadyWindow == .ready)
    #expect(atBlinkWindow.color == midReadyWindow.color) // steady — no interpolation in Ready
    #expect(atBlinkWindow.color.alpha == 1.0)
}

/// Acceptance item 3: a Tile idle between `readyWindow` and `fadeWindow` shows a color partway
/// interpolated between green and grey, proportional to elapsed idle time within that window.
/// Exact-boundary case at `readyWindow` (fraction `0`, i.e. still exactly Ready's green) per
/// this task's Test seam, plus a quarter-way point checked both as a `colorFraction` value and
/// as an actual color strictly between green and grey (not clamped to either endpoint).
@Test func idleBetweenReadyAndFadeWindowInterpolatesProportionally() {
    let store = ActivityStateStore(blinkWindow: 10, readyWindow: 90, fadeWindow: 3600)
    store.recordOutput(paneId: "%1", at: referenceDate)

    let atReadyWindow = store.phase(for: "%1", now: referenceDate.addingTimeInterval(90))
    let quarterway = store.phase(for: "%1", now: referenceDate.addingTimeInterval(90 + (3600 - 90) / 4))

    guard case .fading(let fractionAtStart) = atReadyWindow else {
        Issue.record("expected .fading at readyWindow, got \(atReadyWindow)")
        return
    }
    #expect(fractionAtStart == 0.0)
    #expect(atReadyWindow.color == ActivityPhase.ready.color) // continuous with Ready at the seam

    guard case .fading(let fractionQuarter) = quarterway else {
        Issue.record("expected .fading at the quarter mark, got \(quarterway)")
        return
    }
    #expect(abs(fractionQuarter - 0.25) < 0.0001)

    let readyColor = ActivityPhase.ready.color
    let idleColor = ActivityPhase.idle.color
    #expect(quarterway.color.alpha == 1.0)
    #expect(quarterway.color != readyColor)
    #expect(quarterway.color != idleColor)
    // Strictly between the two endpoints on the channel that actually moves (red rises from
    // green's low red toward grey's higher red as the fraction increases).
    #expect(quarterway.color.red > readyColor.red)
    #expect(quarterway.color.red < idleColor.red)
}

/// Acceptance item 4: a Tile idle past `fadeWindow` shows steady grey at 100% opacity — never
/// dimmer, never further along than fully grey. Exact-boundary case at `fadeWindow` itself
/// (must already be `.idle`, not `.fading(colorFraction: 1)`), plus a far-future instant to
/// pin "never further along" — a regression that let `colorFraction` exceed `1` and darken
/// past grey, or let opacity drop (SPEC §1's explicitly-reversed 20%-floor design), fails this.
@Test func idlePastFadeWindowShowsSteadyGreyAtFullOpacity() {
    let store = ActivityStateStore(blinkWindow: 10, readyWindow: 90, fadeWindow: 3600)
    store.recordOutput(paneId: "%1", at: referenceDate)

    let atFadeWindow = store.phase(for: "%1", now: referenceDate.addingTimeInterval(3600))
    let farFuture = store.phase(for: "%1", now: referenceDate.addingTimeInterval(3600 * 1000))

    #expect(atFadeWindow == .idle)
    #expect(farFuture == .idle)
    #expect(atFadeWindow.color.alpha == 1.0)
    #expect(farFuture.color.alpha == 1.0)
    #expect(atFadeWindow.color == farFuture.color) // never further along than fully grey
}

/// Acceptance item 5: producing new output resets a Tile from any phase back to Blinking.
/// Exercised from deep in Idle specifically — the phase furthest from Blinking — so this can't
/// pass by accident of a boundary that happened to already read `.blinking`.
@Test func newOutputResetsToBlinkingFromIdle() {
    let store = ActivityStateStore(blinkWindow: 10, readyWindow: 90, fadeWindow: 3600)
    store.recordOutput(paneId: "%1", at: referenceDate)
    let beforeReset = store.phase(for: "%1", now: referenceDate.addingTimeInterval(10_000))
    #expect(beforeReset == .idle)

    let newOutputAt = referenceDate.addingTimeInterval(10_000)
    store.recordOutput(paneId: "%1", at: newOutputAt)
    let afterReset = store.phase(for: "%1", now: newOutputAt.addingTimeInterval(2))

    #expect(afterReset == .blinking)
}

/// `PreviewClientLifecycle`'s reason for `muteOutput` existing: a `recordOutput` whose `at`
/// falls before the muted deadline must be ignored entirely — the pane must stay exactly where
/// it was, not reset to Blinking — while one at or after the deadline takes effect normally.
@Test func mutedOutputIsIgnoredUntilTheMuteWindowEnds() {
    let store = ActivityStateStore(blinkWindow: 10, readyWindow: 90, fadeWindow: 3600)
    store.recordOutput(paneId: "%1", at: referenceDate)
    #expect(store.phase(for: "%1", now: referenceDate.addingTimeInterval(50)) == .ready)

    store.muteOutput(paneId: "%1", until: referenceDate.addingTimeInterval(60))
    store.recordOutput(paneId: "%1", at: referenceDate.addingTimeInterval(55))
    // Falsifiable: recordOutput taking effect here would reset to `.blinking` at this `now`.
    #expect(store.phase(for: "%1", now: referenceDate.addingTimeInterval(56)) == .ready)

    store.recordOutput(paneId: "%1", at: referenceDate.addingTimeInterval(60))
    #expect(store.phase(for: "%1", now: referenceDate.addingTimeInterval(61)) == .blinking)
}

/// Acceptance for the "brief hover" case: a second, shorter `muteOutput` call must not cut the
/// first mute short — the window only ever grows within one pane's overlapping mutes.
@Test func muteOutputExtendsRatherThanShortensAnExistingMute() {
    let store = ActivityStateStore(blinkWindow: 10, readyWindow: 90, fadeWindow: 3600)
    store.recordOutput(paneId: "%1", at: referenceDate)

    store.muteOutput(paneId: "%1", until: referenceDate.addingTimeInterval(60))
    store.muteOutput(paneId: "%1", until: referenceDate.addingTimeInterval(30))

    store.recordOutput(paneId: "%1", at: referenceDate.addingTimeInterval(45))
    #expect(store.phase(for: "%1", now: referenceDate.addingTimeInterval(46)) == .ready)
}

/// `muteAllOutput`'s reason for existing (`StatusBarShell.systemDidWake`): a global mute must
/// suppress `recordOutput` pane-agnostically, not just for panes individually muted via
/// `muteOutput` — the falsifiable distinction from `mutedOutputIsIgnoredUntilTheMuteWindowEnds`
/// above, which only proves the per-pane path.
@Test func muteAllOutputSuppressesRecordOutputAcrossMultipleUnrelatedPanes() {
    let store = ActivityStateStore(blinkWindow: 10, readyWindow: 90, fadeWindow: 3600)
    store.recordOutput(paneId: "%1", at: referenceDate)
    store.recordOutput(paneId: "%2", at: referenceDate)
    #expect(store.phase(for: "%1", now: referenceDate.addingTimeInterval(50)) == .ready)
    #expect(store.phase(for: "%2", now: referenceDate.addingTimeInterval(50)) == .ready)

    store.muteAllOutput(until: referenceDate.addingTimeInterval(60))
    store.recordOutput(paneId: "%1", at: referenceDate.addingTimeInterval(55))
    store.recordOutput(paneId: "%2", at: referenceDate.addingTimeInterval(55))

    // Falsifiable: either recordOutput taking effect here would reset its pane to `.blinking`
    // at this `now` — neither pane was ever individually muted via `muteOutput`.
    #expect(store.phase(for: "%1", now: referenceDate.addingTimeInterval(56)) == .ready)
    #expect(store.phase(for: "%2", now: referenceDate.addingTimeInterval(56)) == .ready)
}

/// Mirrors `muteOutputExtendsRatherThanShortensAnExistingMute`'s shape for the global mute.
@Test func muteAllOutputExtendsRatherThanShortensAnExistingMute() {
    let store = ActivityStateStore(blinkWindow: 10, readyWindow: 90, fadeWindow: 3600)
    store.recordOutput(paneId: "%1", at: referenceDate)

    store.muteAllOutput(until: referenceDate.addingTimeInterval(60))
    store.muteAllOutput(until: referenceDate.addingTimeInterval(30))

    store.recordOutput(paneId: "%1", at: referenceDate.addingTimeInterval(45))
    #expect(store.phase(for: "%1", now: referenceDate.addingTimeInterval(46)) == .ready)
}

/// `recordOutput` timestamped at/after the global mute deadline is recorded normally — mirrors
/// the per-pane deadline-boundary behavior asserted in
/// `mutedOutputIsIgnoredUntilTheMuteWindowEnds`.
@Test func recordOutputAtOrAfterGlobalMuteDeadlineIsRecordedNormally() {
    let store = ActivityStateStore(blinkWindow: 10, readyWindow: 90, fadeWindow: 3600)
    store.recordOutput(paneId: "%1", at: referenceDate)
    store.muteAllOutput(until: referenceDate.addingTimeInterval(60))

    store.recordOutput(paneId: "%1", at: referenceDate.addingTimeInterval(60))
    #expect(store.phase(for: "%1", now: referenceDate.addingTimeInterval(61)) == .blinking)
}

/// `forceRecordOutput` must still bypass the global mute, same as it already bypasses the
/// per-pane one (`forceRecordOutputIgnoresAnActiveMute`).
@Test func forceRecordOutputIgnoresAnActiveGlobalMute() {
    let store = ActivityStateStore(blinkWindow: 10, readyWindow: 90, fadeWindow: 3600)
    store.recordOutput(paneId: "%1", at: referenceDate)
    store.muteAllOutput(until: referenceDate.addingTimeInterval(60))

    // Falsifiable: `recordOutput` at this same instant would be dropped by the active global
    // mute (per `recordOutputAtOrAfterGlobalMuteDeadlineIsRecordedNormally` above) —
    // `forceRecordOutput` must not be.
    store.forceRecordOutput(paneId: "%1", at: referenceDate.addingTimeInterval(55))

    #expect(store.phase(for: "%1", now: referenceDate.addingTimeInterval(56)) == .blinking)
}

/// Bug fix: an Inline Reply sent while `PreviewClientLifecycle`'s zoom mute is still covering
/// the pane (the popup opened moments before the reply was sent) must still make the Tile show
/// as active immediately, not wait out that mute window — `forceRecordOutput` is the seam
/// `HoverPreviewController.sendInlineReply` uses for that, and unlike `recordOutput` it must not
/// be silently dropped by an active `muteOutput` deadline.
@Test func forceRecordOutputIgnoresAnActiveMute() {
    let store = ActivityStateStore(blinkWindow: 10, readyWindow: 90, fadeWindow: 3600)
    store.recordOutput(paneId: "%1", at: referenceDate)
    store.muteOutput(paneId: "%1", until: referenceDate.addingTimeInterval(60))

    // Falsifiable: `recordOutput` at this same instant would be dropped by the active mute
    // (per `mutedOutputIsIgnoredUntilTheMuteWindowEnds` above) — `forceRecordOutput` must not be.
    store.forceRecordOutput(paneId: "%1", at: referenceDate.addingTimeInterval(55))

    #expect(store.phase(for: "%1", now: referenceDate.addingTimeInterval(56)) == .blinking)
}
