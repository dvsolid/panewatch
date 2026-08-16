import Foundation
import Testing
@testable import TmuxCore

@Suite struct ControlModeProtocolParserTests {
    @Test func outputLineParsesToOutputEventWithPaneId() {
        let event = ControlModeProtocolParser.parse("%output %65 H")
        #expect(event == .output(paneId: "%65"))
    }

    /// SPEC §230: a single `echo` produced ~25 `%output` lines, mostly cursor-positioning
    /// and colour escape sequences, payload split one character per line — arbitrary payload
    /// shape must never change which pane id is extracted.
    @Test(arguments: [
        "%output %65 \u{1B}[38;5;10m",
        "%output %65 ",
        "%output %9 multiple words in the payload",
    ])
    func arbitraryPayloadShapesStillExtractPaneId(line: String) {
        let event = ControlModeProtocolParser.parse(line)
        let expectedPaneId = line.split(separator: " ")[1]
        #expect(event == .output(paneId: String(expectedPaneId)))
    }

    @Test func exitLineParsesToExitEvent() {
        let event = ControlModeProtocolParser.parse("%exit")
        #expect(event == .exit)
    }

    /// `%some-future-notification` is invented — no such notification exists yet. Forward
    /// compatibility with tmux versions that add new notification types (SPEC §238) requires
    /// unrecognized lines to classify silently, never throw.
    @Test(arguments: [
        "%begin 1786664109 25370040 0",
        "%session-changed $12 ztest1",
        "%some-future-notification with arbitrary args",
    ])
    func nonOutputNonExitNotificationsClassifyAsOther(line: String) {
        let event = ControlModeProtocolParser.parse(line)
        #expect(event == .other)
    }

    /// TASK-029: `%end` is the reply to the implicit `attach-session` command `-C attach`
    /// itself issues — the only `%begin`/`%end`/`%error` triple a *read-only* control client
    /// (never writes further commands) will ever see. Its presence is therefore the
    /// protocol-level proof an attach actually succeeded, distinct from `%error` (classified
    /// as `.other`, the same as before) — live-verified: a nonexistent-session attach produces
    /// `%begin`/`<error text>`/`%error`/`%exit`, never `%end`.
    @Test func endLineParsesToAttachConfirmedEvent() {
        let event = ControlModeProtocolParser.parse("%end 1786664109 25370040 0")
        #expect(event == .attachConfirmed)
    }

    /// `%error` is the failure counterpart to `%end` — must never be conflated with it.
    @Test func errorLineClassifiesAsOtherNotAttachConfirmed() {
        let event = ControlModeProtocolParser.parse("%error 1786864109 1 0")
        #expect(event == .other)
    }

    @Test func specTranscriptFixtureClassifiesEveryLineCorrectly() {
        for (line, expected) in controlModeTranscriptFixture {
            #expect(ControlModeProtocolParser.parse(line) == expected, "line: \(line)")
        }
    }

    /// SPEC §230: the payload is ANSI escape soup carrying no information this app needs.
    /// `.output`'s only associated value is `paneId` — reflecting the case's payload proves
    /// there is no second slot a payload string could hide in, regardless of what `parse`
    /// does internally. This would fail the moment someone adds a `data:` field to the case.
    @Test func outputEventCarriesOnlyPaneIdNoPayloadSlot() throws {
        let event = ControlModeEvent.output(paneId: "%65")
        let caseMirror = Mirror(reflecting: event)
        let associatedValue = try #require(caseMirror.children.first?.value)
        let payloadMirror = Mirror(reflecting: associatedValue)
        #expect(payloadMirror.children.count == 1)
        #expect(payloadMirror.children.first?.label == "paneId")
    }
}
