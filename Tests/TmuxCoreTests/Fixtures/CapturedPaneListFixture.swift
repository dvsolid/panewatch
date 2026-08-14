/// `list-panes -a -F <ProcessTmuxGateway.paneFormat>` output captured from a live tmux 3.6a
/// server on the reference machine (SPEC.md's "Technical Findings" data, re-captured here).
/// Frozen as a literal string — tests never touch a live tmux server (CLAUDE.md).
///
/// Covers: plain-shell pane with an empty title (`%28`), Pi detected via `zsh` (`%29`) and
/// `node` (`%54`) commands, Claude Code (`%9`), a not-agent pane whose title is the machine
/// hostname (`%5`, `%11`), a second window within one session (`qtc-auto` windows 1 and 2),
/// and a grouped session (`t2q`) with a dotted `window_name` (`2.1.228`) on both its panes.
///
/// Shared across `PaneDiscoveryTests` (TASK-002) and `AgentDetectorTests` (TASK-003) so both
/// exercise the exact same captured data — no `private` here, deliberately: internal (the
/// Swift default) is visible to every file in the `TmuxCoreTests` target.
let capturedPaneListFixture = """
%28|billing-advisor|1|zsh|1|zsh||8578|/dev/ttys060|/Users/dmitryv/Work/Projects/billing/rc-billing-advisor|0||0
%29|billing-advisor|1|zsh|2|zsh|π - rc-billing-advisor|25236|/dev/ttys056|/Users/dmitryv/Work/Projects/billing/rc-billing-advisor|0||0
%54|qtc-auto|1|main|2|node|π - qtc-ops-automation|29302|/dev/ttys031|/Users/dmitryv/Work/Projects/billing/qtc-ops-automation|0||0
%9|qtc-auto|1|main|3|2.1.222|✳ task-execution-workflow|8569|/dev/ttys032|/Users/dmitryv/Work/Projects/billing/qtc-ops-automation|0||1
%11|qtc-auto|2|run|1|node|LMYG2LW3F|8870|/dev/ttys034|/Users/dmitryv/Work/Projects/billing/qtc-ops-automation/frontend|0||0
%5|ngrok|1|ngrok|1|ngrok|LMYG2LW3F|8224|/dev/ttys028|/Users/dmitryv/Work/Projects/billing/text2quote|0||0
%45|t2q|1|2.1.228|1|zsh||32244|/dev/ttys027|/Users/dmitryv/Work/Projects/billing/text2quote|1|t2q|0
%51|t2q|1|2.1.228|2|2.1.228|✳ Investigate JIRA bug BZS-19252|54430|/dev/ttys050|/Users/dmitryv/Work/Projects/billing/text2quote|1|t2q|0
"""
