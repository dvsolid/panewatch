import TmuxCore

/// The captured tmux 3.6a control-mode transcript from SPEC.md §3.2 (`tmux -C attach -t
/// ztest1`) — verified behaviour, not a proposal. Excludes the leading `$ tmux -C attach
/// -t ztest1` shell prompt line, which is never emitted by tmux itself and so is not
/// something `ControlModeProtocolParser` is ever asked to classify.
///
/// Each entry pairs one transcript line with the `ControlModeEvent` it must classify to —
/// TASK-024's acceptance item "every line in SPEC.md §3.2's captured tmux 3.6a transcript
/// classifies correctly." `%end`'s expected event was revised by TASK-029 from `.other` to
/// `.attachConfirmed` — SPEC.md's transcript itself is unchanged (still the raw captured
/// bytes), only the classification TASK-024 originally assigned this specific line.
let controlModeTranscriptFixture: [(line: String, expected: ControlModeEvent)] = [
    ("%begin 1786664109 25370040 0", .other),
    ("%end 1786664109 25370040 0", .attachConfirmed),
    ("%session-changed $12 ztest1", .other),
    ("%output %65 H", .output(paneId: "%65")),
    ("%output %65 E", .output(paneId: "%65")),
    ("%output %65 L", .output(paneId: "%65")),
]
