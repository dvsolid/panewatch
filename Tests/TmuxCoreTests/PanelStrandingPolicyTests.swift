import Testing
@testable import TmuxCore

@Suite struct PanelStrandingPolicyTests {
    private func input(
        visible: Bool = true,
        onScreen: Bool? = true,
        since: Double = 5,
        healed: Bool = false
    ) -> PanelStrandingPolicy.Input {
        .init(appKitVisible: visible, windowServerOnScreen: onScreen, timeSinceShown: since, alreadyHealed: healed)
    }

    // MARK: - stranded -> heal

    @Test func clickOnVisiblePanelTheWindowServerReportsOffScreenHeals() {
        #expect(PanelStrandingPolicy.decide(.click, input(onScreen: false)) == .heal)
    }

    @Test func clickOnVisiblePanelWithNoWindowServerEntryHeals() {
        #expect(PanelStrandingPolicy.decide(.click, input(onScreen: nil)) == .heal)
    }

    @Test func settleCheckOnStrandedPanelHeals() {
        #expect(PanelStrandingPolicy.decide(.settleCheck, input(onScreen: false)) == .heal)
    }

    @Test func strandedIsBelievedExactlyAtTheSettleInterval() {
        let atSettle = input(onScreen: false, since: PanelStrandingPolicy.settleInterval)
        #expect(PanelStrandingPolicy.decide(.click, atSettle) == .heal)
    }

    // MARK: - healthy panel is never rebuilt

    @Test func clickOnHealthyVisiblePanelHides() {
        #expect(PanelStrandingPolicy.decide(.click, input(onScreen: true)) == .hide)
    }

    @Test func clickOnHiddenPanelShows() {
        #expect(PanelStrandingPolicy.decide(.click, input(visible: false, onScreen: nil)) == .show)
    }

    @Test func settleCheckOnAHealthyPanelConfirmsItHealthy() {
        #expect(PanelStrandingPolicy.decide(.settleCheck, input(onScreen: true)) == .confirmedHealthy)
    }

    @Test func clickOnAHealthyPanelNeverReportsConfirmedHealthy() {
        #expect(PanelStrandingPolicy.decide(.click, input(onScreen: true)) == .hide)
    }

    @Test func settleCheckLeavesAHiddenPanelAlone() {
        #expect(PanelStrandingPolicy.decide(.settleCheck, input(visible: false, onScreen: nil)) == .none)
    }

    @Test func absentFlagInsideTheSettleIntervalIsNotStranded() {
        let justShown = input(onScreen: nil, since: PanelStrandingPolicy.settleInterval - 0.01)
        // A rapid second click toggles normally; the post-show check does nothing yet.
        #expect(PanelStrandingPolicy.decide(.click, justShown) == .hide)
        #expect(PanelStrandingPolicy.decide(.settleCheck, justShown) == .none)
    }

    // MARK: - at most one heal per attempt

    @Test func strandedAfterAHealGivesUpInsteadOfHealingAgain() {
        let again = input(onScreen: false, healed: true)
        #expect(PanelStrandingPolicy.decide(.click, again) == .giveUp)
        #expect(PanelStrandingPolicy.decide(.settleCheck, again) == .giveUp)
    }

    @Test func aHealedHealthyPanelStillTogglesNormally() {
        #expect(PanelStrandingPolicy.decide(.click, input(onScreen: true, healed: true)) == .hide)
        #expect(PanelStrandingPolicy.decide(.click, input(visible: false, healed: true)) == .show)
    }

    /// Replays the shell's bookkeeping (set on heal, cleared on `.confirmedHealthy` or a show)
    /// against the policy: a replacement that settles healthy must not leave a later, separate
    /// stranding looking like "already healed".
    @Test func aLaterStrandingAfterAConfirmedHealthyReplacementHealsAgain() {
        var healed = false
        func run(_ trigger: PanelStrandingPolicy.Trigger, onScreen: Bool?) -> PanelStrandingPolicy.Action {
            let action = PanelStrandingPolicy.decide(trigger, input(onScreen: onScreen, healed: healed))
            switch action {
            case .heal: healed = true
            case .confirmedHealthy, .show: healed = false
            default: break
            }
            return action
        }
        #expect(run(.click, onScreen: false) == .heal)
        #expect(run(.settleCheck, onScreen: true) == .confirmedHealthy)
        // Days later, the panel is stranded again.
        #expect(run(.click, onScreen: false) == .heal)
    }

    @Test func aReplacementThatIsItselfStrandedStillGivesUpOnTheSettleCheck() {
        #expect(PanelStrandingPolicy.decide(.settleCheck, input(onScreen: false, healed: true)) == .giveUp)
    }
}
