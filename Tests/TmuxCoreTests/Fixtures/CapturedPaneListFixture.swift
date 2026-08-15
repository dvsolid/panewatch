/// `list-panes -a -F <ProcessTmuxGateway.paneFormat>` output shaped after a real capture from a
/// live tmux 3.6a server on the reference machine (SPEC.md's "Technical Findings" data), with
/// session names, paths, hostname, and ticket text replaced by placeholders — the original
/// capture was from real project work, and only its structural shape (field values, the
/// sticky-title/dotted-window-name/session-group quirks it demonstrates) matters here, not the
/// literal project names. Frozen as a literal string — tests never touch a live tmux server
/// (CLAUDE.md).
///
/// Covers: plain-shell pane with an empty title (`%28`), Pi detected via `zsh` (`%29`) and
/// `node` (`%54`) commands, Claude Code (`%9`), a not-agent pane whose title is the machine
/// hostname (`%5`, `%11`), a second window within one session (`ops-auto` windows 1 and 2),
/// and a grouped session (`wgt`) with a dotted `window_name` (`2.1.228`) on both its panes.
///
/// Shared across `PaneDiscoveryTests` (TASK-002) and `AgentDetectorTests` (TASK-003) so both
/// exercise the exact same captured data — no `private` here, deliberately: internal (the
/// Swift default) is visible to every file in the `TmuxCoreTests` target.
///
/// The trailing `#{window_activity}` column (added for the app-restart Activity Phase fix) was
/// not part of the original capture, since that column didn't exist in the format string yet —
/// each row below has a synthetic epoch appended, an arbitrary fixed moment (`1700000000`,
/// 2023-11-14T22:13:20Z) rather than a re-capture, since only its presence/parseability matters
/// to `PaneDiscoveryTests`/`AgentDetectorTests`; none of them assert on its value.
let capturedPaneListFixture = """
%28|widget-advisor|1|zsh|1|zsh||8578|/dev/ttys060|/Users/user/Projects/acme/widget-advisor|0||0|1700000000
%29|widget-advisor|1|zsh|2|zsh|π - widget-advisor|25236|/dev/ttys056|/Users/user/Projects/acme/widget-advisor|0||0|1700000000
%54|ops-auto|1|main|2|node|π - ops-automation|29302|/dev/ttys031|/Users/user/Projects/acme/ops-automation|0||0|1700000000
%9|ops-auto|1|main|3|2.1.222|✳ task-execution-workflow|8569|/dev/ttys032|/Users/user/Projects/acme/ops-automation|0||1|1700000000
%11|ops-auto|2|run|1|node|HOSTX7K2Q9|8870|/dev/ttys034|/Users/user/Projects/acme/ops-automation/frontend|0||0|1700000000
%5|ngrok|1|ngrok|1|ngrok|HOSTX7K2Q9|8224|/dev/ttys028|/Users/user/Projects/acme/quotegen|0||0|1700000000
%45|wgt|1|2.1.228|1|zsh||32244|/dev/ttys027|/Users/user/Projects/acme/quotegen|1|wgt|0|1700000000
%51|wgt|1|2.1.228|2|2.1.228|✳ Investigate JIRA bug WGT-4821|54430|/dev/ttys050|/Users/user/Projects/acme/quotegen|1|wgt|0|1700000000
"""
