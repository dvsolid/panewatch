# tmuxer-mac — Native macOS Agent Status Bar

## Vision

A native macOS app that monitors and manages AI coding agent tmux sessions across all terminal applications (Ghostty, iTerm2, Terminal.app) and displays a vertical floating status bar with real-time activity indicators.

## Core Problem

When running multiple AI coding agents simultaneously (Claude Code, Pi, Codex) across tmux sessions, there is no quick way to:
1. See which agents are actively producing output vs idle
2. Know how long an agent has been idle
3. Quickly focus on or open a specific agent's terminal

Existing solutions (top, tmux list-panes, tmux capture-pane) are CLI-only and require terminal context.

## Requirements

### 1. Status Bar (Primary UI)

**Layout:** Vertical floating bar, pinned to left or right edge of screen.

**Item Card — each agent:**
- **Square tile** with:
  - **Color state:**
    - 🟢 **Green** — pane produced output within the *active window* (see below)
    - ⬜ **Grey** — idle, opacity fades over time
    - Fade scale: 100% → 20% opacity over 60 minutes idle. **Never fade to 0** — an agent stuck for an hour is exactly the one you want to notice.
  - **Label** — session name or project name (e.g., "qtc-auto", "t2q", "squid")
  - **Agent type badge** — π (Pi), 🟣 (Claude Code), 🤖 (Codex), or auto-detected
  - **Optional task indicator** — if Claude Code has a visible prompt task (e.g., "✳ BZS-19252")

**Timing (single source of truth — do not restate these elsewhere):**

| Parameter | Default | Meaning |
|---|---|---|
| `probeInterval` | 5s | How often the polling `ActivitySource` samples each pane. Ignored by the event-driven source. |
| `activeWindow` | 15s | A pane is green if `now - lastOutputAt < activeWindow`. |
| `discoveryInterval` | 30s | How often the session/pane topology is re-scanned. |

**Constraint:** `activeWindow` must be ≥ 2 × `probeInterval`. With polling, output is only detectable at sample boundaries, so a window narrower than two intervals makes tiles flicker grey between samples of a continuously-running agent. The event-driven source (§3) has no such constraint; the same `activeWindow` just becomes exact rather than quantized.

### 2. Agent Detection & Discovery

**What to monitor:**
- All tmux panes across all sessions
- Panes running terminal-based coding agents

**Detection: title is the strong signal, `pane_current_command` is the weak one.**

This is the reverse of the intuitive ordering, and it is what the live data shows. Observed on the reference machine:

```
%29  cmd=zsh      title=π - rc-billing-advisor        ← Pi, but cmd is zsh
%14  cmd=zsh      title=π - rc-cli                    ← Pi, but cmd is zsh
%54  cmd=node     title=π - qtc-ops-automation        ← Pi, cmd is node
%58  cmd=node     title=π - squid-ai-test             ← Pi, cmd is node
%9   cmd=2.1.222  title=✳ task-execution-workflow     ← Claude Code
%24  cmd=2.1.226  title=✳ Continue the loop           ← Claude Code, different version
%1   cmd=Python   title=LMYG2LW3F                     ← not an agent
```

Any rule keyed on `cmd=node` misses most real Pi panes. **What distinguishes the `zsh` cases from the `node` cases is not established** — plausibly how Pi was launched (direct exec vs. wrapper script vs. resumed job), but this was not tested. `%54` and `%58` run the same agent as `%29` and `%14` yet report `node`, so the field is inconsistent even within one agent type. Treat the *observation* as reliable and the *cause* as unknown; that alone is sufficient reason not to depend on the field.

**Detection ladder (first match wins):**

1. **Title pattern** — cheap, comes free with the `list-panes` format string, no extra process spawn.
   - Pi: title starts with `π` (typically `π - <project>`)
   - Claude Code: title starts with `✳ ` (the task indicator)
2. **Descendant process inspection** — the robust fallback. Walk children of `pane_pid` and match on argv. This is the only method that survives both the shell-wrapping problem above and Claude Code version bumps.
3. **`pane_current_command`** — corroborating evidence only, never the sole basis for a positive ID.

**Do not match Claude Code on `pane_current_command` matching `2.1.XXX`.** That string is the versioned binary name and changes on every Claude Code release; a rule built on it ships a patch per upstream update. Use it to *confirm* a title match, never to drive one.

**Negative signals (cheap exclusions, apply before the ladder):**
- `pane_title` equal to the machine hostname (e.g. `LMYG2LW3F`) — this is tmux's default when nothing has set a title, so it positively indicates "no agent branded this pane."
- `pane_title` equal to `:<path>` or empty — same reasoning.
- `pane_current_command` in {`ngrok`, `ssh`, `zsh`, `bash`, `fish`} *and* no title match *and* no agent descendant.

**Discovery method:**
- One `tmux list-panes -a -F '<format>'` call gets the entire topology in a single subprocess spawn. Do **not** walk `list-sessions` → `list-windows` → `list-panes`; that is O(sessions × windows) spawns for the same data.
- Format string should include at minimum:
  `#{pane_id}|#{session_name}|#{window_index}|#{window_name}|#{pane_index}|#{pane_current_command}|#{pane_title}|#{pane_pid}|#{pane_tty}|#{pane_current_path}|#{session_grouped}|#{session_group}|#{alternate_on}`
- Re-scan every `discoveryInterval` (30s) and reconcile against cached state by `pane_id`.
- Descendant-process inspection (ladder step 2) is the only expensive step; run it once per newly-seen `pane_id` and cache the result for the pane's lifetime.

### 2.1 Session groups — deduplicate on `pane_id`

`tmux list-sessions` on the reference machine reports:

```
t2q  grouped=1  group=t2q  size=1  attached=1
```

Sessions in a **group share their windows**. When a group has more than one member, the same pane is reachable under every member's session name, and a bar keyed on `session:window.pane` renders duplicate tiles for one agent.

**Status:** the group itself is confirmed present (`t2q`), but `session_group_size=1` today — so the duplication is **latent, not currently reproducing**. It appears the moment a second session joins the group (`tmux new-session -t t2q`), which is a normal thing to do when attaching the same work from a second terminal. Design for it now; it is cheap to key on `pane_id` from the start and expensive to retrofit once session names are threaded through the model.

**Rule: `pane_id` (`%51`) is the identity of an agent. Everything else is display data.**

`pane_id` is server-unique, stable for the pane's entire life, and unaffected by grouping. Session names, window indices, and pane indices all renumber as panes and windows are closed, so they must never be used as a key — only for rendering and for building target strings at click time.

When a pane surfaces under multiple grouped sessions, pick one session name for display (prefer an attached one; break ties alphabetically for stability) and collapse the rest.

### 3. Activity Detection

Activity detection sits behind a protocol seam with two implementations. The polling source ships in Phase 1 because it is trivial; the event-driven source replaces it in Phase 2 and is strictly better. **Nothing above this layer may know which source is in use.**

```swift
protocol ActivitySource: AnyObject {
    /// Panes to watch. Called on every discovery pass; implementations
    /// diff against their current set and attach/detach as needed.
    func setWatchedPanes(_ paneIds: Set<String>)

    /// Fires when a pane produces output. Coalesced to at most one event
    /// per pane per 250ms so a chatty repaint cannot flood the UI.
    /// (250ms is a starting design choice, not a measured figure — tune
    /// once the control-mode source is running against real agents.)
    var onOutput: ((_ paneId: String, _ at: Date) -> Void)? { get set }
}
```

The consumer keeps one `lastOutputAt: [String: Date]` map and derives everything from it:

```swift
isActive     = Date().timeIntervalSince(lastOutputAt[paneId] ?? .distantPast) < activeWindow
idleDuration = Date().timeIntervalSince(lastOutputAt[paneId] ?? processStart)
```

#### 3.1 `PollingActivitySource` (Phase 1)

Every `probeInterval` (5s), for each watched pane, capture the visible screen and compare a hash against the previous sample. Emit an event when the hash changes.

```
tmux capture-pane -t %51 -p -J
```

**Capture the visible screen only. Do not pass `-S`.** See §3.3 for why.

Cost is one subprocess per pane per interval. At ~10 agent panes on a 5s interval that is roughly 2 spawns/sec — acceptable, but the main reason this source is temporary. *(Estimate, not a measurement.)*

**Measured signal quality — better than expected.** Six agent panes were hashed twice, 6s apart:

```
%51 stable   %24 stable   %55 stable   %58 stable   %29 stable
%9  CHANGED  ← ✳ Photosynthesizing… (5s · thinking with high effort)
```

The single change was a **true positive**: that pane was genuinely working, and the diff was its elapsed-second counter. Idle agent panes did **not** self-repaint. Both Pi and Claude Code hold a static screen when waiting for input, so the naive hash does not produce false "active" readings — the concern that a continuously-repainting status line would peg every tile green is not borne out. **[verified]**

Usefully, Claude Code's working spinner ticks its elapsed counter every second, which gives the polling source a reliable heartbeat for the entire duration of a long tool call.

**Known limitations, accepted for Phase 1:**
- Output that starts and finishes entirely between two samples is invisible; a pane emitting one line every 6s will flicker.
- The residual risk runs the *other* way from the repaint concern: an agent that is genuinely busy while its visible screen stays static reads as idle. Claude Code's spinner covers this case; an agent without a live progress indicator would not be covered.
- Hashing only sees the visible screen, so output that scrolls past between samples is counted once, not proportionally.

All three disappear under §3.2, which observes bytes rather than screen states.

#### 3.2 `ControlModeActivitySource` (Phase 2) — the real design

tmux pushes output events; polling for them is unnecessary. Attaching a client in **control mode** streams one `%output <pane-id> <data>` line for every byte written to any pane in the attached session:

```
$ tmux -C attach -t ztest1
%begin 1786664109 25370040 0
%end 1786664109 25370040 0
%session-changed $12 ztest1
%output %65 H
%output %65 E
%output %65 L
...
```

This is verified behaviour on tmux 3.6a, not a proposal.

**Scope: one control client per session.** Verified — a control client attached to `ztest1` receives no events from `ztest2`. The source therefore maintains a supervised pool of control clients, spawning one per session on discovery and reaping it when the session disappears.

**Attach flags: `-f read-only,ignore-size`.**
- `read-only` — the client must never be able to inject input into a live agent pane.
- `ignore-size` — keeps the invisible client out of session size negotiation. The reference machine runs `window-size=latest`, under which an extra client happens to be benign, but `window-size=smallest` would let a monitoring client shrink the user's real terminal. Do not rely on the server's current setting.
- **Never pass `no-output`.** It suppresses exactly the `%output` events this source exists to receive. (It is the correct flag for a control client used only for command dispatch — see §4 — which is why it is easy to copy into the wrong place.)

**Timestamp the payloads. Never parse them.** The data field is ANSI escape soup — a single `echo HELLO_FROM_ONE` produced ~25 `%output` lines, most of them cursor-positioning and colour sequences, with the payload split one character per line. The only information this source needs is *which pane* and *when*. Any attempt to interpret the bytes is unnecessary and would be a source of false negatives.

**Note on granularity vs. §3.1.** This source fires on *bytes written*, whereas the polling source fires on *visible screen changed*. These differ: a repaint that redraws the screen identically emits `%output` but no hash change. Measurement in §3.1 shows idle agents emit nothing at all, so in practice both agree — but where they diverge, this source is the more sensitive of the two, and `activeWindow` (§1) is what smooths it.

**Supervision requirements** (this is the bulk of the work, and why it is Phase 2 rather than Phase 1):
- A control client emits `%exit` and terminates when its session is killed → reap and remove from pool.
- The tmux **server** exiting kills every client at once → detect, clear the pool, and retry attachment with backoff rather than spinning.
- The client terminates if its stdin closes. Hold stdin open for the process lifetime; do not connect it to a pipe that can drain. *(This is a real failure mode — the first attempt at verifying this design saw the client exit with `%exit` immediately for exactly this reason.)*
- Parse the protocol line-wise and tolerate unknown `%`-prefixed notifications; tmux adds new ones between versions.

#### 3.3 The alternate screen (corrects a misdiagnosis)

An earlier investigation attributed empty `capture-pane` output to **vi mode** in Claude Code. That diagnosis is wrong. All three Claude Code panes on the reference machine capture their full visible content, and all three report `pane_in_mode=0`.

The actual mechanism is the **alternate screen**. Pane `%24` reports `alternate_on=1`, and under an active alternate screen:

- `capture-pane -p` (no `-S`) returns the **visible alternate screen** — correct, and what this app wants.
- `capture-pane -p -S -N` returns the **normal screen's scrollback**, i.e. whatever was on screen *before* the agent launched. On `%24` this returned git rebase output from a previous command — stale content that never changes, which would make a busy agent look permanently idle.
- `capture-pane -p -a` swaps which of the two screens is read.

**Rule: capture with `-p -J` and no `-S` flag.** The "detect vi mode and probe via process CPU" workaround previously proposed here is unnecessary and is removed.

#### 3.4 Remaining edge cases

- **Ghostty vs iTerm**: both use standard tmux panes; clients differ by TTY. No impact on detection.
- **Nested tmux**: an inner tmux server is invisible to the outer one — its panes appear as a single pane running `tmux`. Detect `pane_current_command == "tmux"` and either skip the pane or (Phase 4) connect to the inner server's socket separately. Do not attempt to infer inner panes from captured content.
- **Dotted window names**: `t2q:2.1.228` — tmux parses `.` as the window/pane separator, so this target string is ambiguous. **Always build targets from `#{window_index}` and `#{pane_index}`, never from `window_name`.** `t2q:1.2` is unambiguous; `t2q:2.1.228` is not. Since §2.1 already establishes `pane_id` as identity, the cleanest form is to target `%51` directly wherever tmux accepts a pane id.

### 4. Click Behavior

**Single click on tile:**

1. **Focus an existing client** — if the pane's session already has an attached client:
   - `tmux select-window -t '<session>:<window_index>'` then `tmux select-pane -t <pane_id>`
     (`pane_id` already carries its `%` sigil — the target is `%51`, not `%%51`. Both forms verified against the live server.)
   - Resolve the client's `#{client_tty}` → owning terminal app, and activate that app via AppleScript.
   - **Do not use `attach` on this path.** `attach` always creates an *additional* client rather than focusing the existing one, leaving the user with two clients fighting over the same session. `select-window`/`select-pane` retarget the client that is already there.
2. **Open a new terminal** — only when the session has no attached client:
   - **Ghostty**: `open -a Ghostty --args -e tmux attach -t '<session>:<window_index>.<pane_index>'`
   - **iTerm**: `open -a iTerm`, then `osascript` to write the same command to a new tab.

**Verified:** `tmux attach -t 'session:window.pane'` does accept a pane-level target and selects that pane on attach (confirmed via `%window-pane-changed @25 %68`). The target must be built from **indices**, not names — see §3.4 on dotted window names.

**Priority:** Focus existing → Open new → Fallback (tooltip showing the tmux command for manual use).

**Note on command dispatch:** if the Phase 2 control-mode pool (§3.2) is running, one-shot commands like `select-pane` can be written to an existing control client instead of spawning `tmux(1)`. Such a client must be attached with `no-output` — the opposite of the monitoring clients, which must never carry that flag.

### 5. macOS Integration

**Menu bar access:**
- App sits in menu bar (not dock, not full window)
- Click menu bar icon → toggle status bar visibility
- Right-click → settings, quit

**Window management:**
- Status bar floats above all windows
- Can be dragged to switch sides
- Resizable (min 1 tile, max screen width tiles)

**Accessibility permissions:**
- Required for: controlling terminal app windows (focus, resize)
- Required for: System Events scripting (iTerm window management)
- Graceful degradation: if permissions denied, fall back to "open new terminal" behavior

### 6. Technology Choices

**Stack:** Swift + SwiftUI (native macOS)
- Window management: `AppKit` (`NSWindow`, `NSApplication`)
- tmux communication: subprocess (`tmux` CLI)
- Status bar: custom `NSView` in a borderless, transparent `NSWindow`
- Icon in menu bar: `NSStatusItem`

**Dependencies:**
- `tmux` (system) — **resolve the path at launch; do not hardcode it.** Probe in order: `$TMUX_BIN` if set, `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, `/usr/bin/tmux`, then `which tmux` in a **login** shell as a last resort. On the reference machine only `/opt/homebrew/bin/tmux` exists (`/usr/bin/tmux` does not), and the user's interactive `tmux` is a zsh plugin alias (`_zsh_tmux_plugin_run`) that does not resolve from a non-interactive shell — so never invoke `tmux` bare and never go through the user's shell aliases.
- Verify the version at launch via `tmux -V`. Control mode and the `-f` client flags are long-standing (documented from ~3.2), but **everything in §3.2 was verified only on 3.6a** — the floor below which it breaks is untested. Since the `PollingActivitySource` fallback exists anyway, do not hardcode a precise floor: attempt the control-mode attach, and fall back to polling on any failure. That is correct at every version without needing to know where the boundary is.
- `osascript` (system) — for iTerm/terminal control
- No external network dependencies

### 7. Data Model

```swift
/// Identity is `paneId` and nothing else. See §2.1.
struct AgentPane: Identifiable, Hashable {
    let id: String                   // pane_id, e.g. "%51" — server-unique, stable for life
    let agentType: AgentType

    // --- Display / targeting data. Renumbers as panes and windows close;
    // --- re-read on every discovery pass. Never use as a key.
    var sessionName: String          // e.g. "t2q" (chosen name if grouped)
    var windowIndex: Int             // e.g. 1  — build targets from this, not windowName
    var windowName: String           // e.g. "2.1.228" — display only; contains dots
    var paneIndex: Int               // e.g. 2
    var paneTitle: String            // e.g. "✳ Investigate JIRA bug BZS-19252"
    var currentPath: String          // for deriving a project label
    var panePID: pid_t               // root of the descendant walk in §2

    // --- Live client state
    var attachedClientTTY: String?   // nil when no client attached → click opens a terminal
}

/// Activity is NOT stored on the pane. It lives in one
/// `[String: Date]` keyed by paneId, owned by the ActivitySource
/// consumer, and `isActive` / `idleDuration` are derived (see §3).
/// Keeping it out of the struct is what lets a 250ms output event
/// avoid invalidating the whole topology model.

enum AgentType: String, Codable {
    case pi                          // raw value "pi" — NOT "π"
    case claude
    case codex
    case unknown

    /// Display glyph is presentation, not identity.
    var glyph: String {
        switch self {
        case .pi:      return "π"
        case .claude:  return "🟣"
        case .codex:   return "🤖"
        case .unknown: return "•"
        }
    }
}
```

**Why `AgentType.pi` is `"pi"` and not `"π"`:** the raw value is what lands in the config file (§8, exclusion lists) and in any persisted state. Using the display glyph as the serialized value welds presentation to storage — changing the badge would silently invalidate saved preferences, and a non-ASCII plist key is needless friction. The glyph belongs in a computed property.

### 8. Configuration

**User preferences:**
- Side (left/right)
- Tile size (S/M/L)
- `probeInterval`, `activeWindow`, `discoveryInterval` — defaults and constraint defined in §1; this section must not restate the values
- Idle fade duration (default 60min, floors at 20% opacity — §1)
- Auto-open on click (focus vs new terminal)
- Exclude sessions (user-configurable list, matched on `session_name`)

**Config location:** `~/Library/Preferences/com.yourname.tmuxer.plist` or `~/.config/tmuxer/config.yaml`

## Technical Findings from Investigation

Findings below marked **[verified]** were reproduced against a live tmux 3.6a server (7 sessions, 36 panes, mixed Pi / Claude Code / shell). Findings marked **[assumed]** have not been tested.

### tmux structure
```
tmux session (e.g., "qtc-auto", "t2q")     ← may belong to a GROUP; grouped sessions share windows
  └── tmux window (e.g., "main", "2.1.228", "node")
       └── tmux pane (e.g., %10, %51, %55) ← the only stable identity
```

### Key challenges encountered

1. **Dotted window names** — `t2q:2.1.228` is ambiguous because tmux parses `.` as the window/pane separator. Build targets from `window_index`/`pane_index`, or address `pane_id` directly. **[verified]**
2. **Alternate screen, not vi mode** — the earlier "empty `capture-pane` during vi mode" diagnosis was wrong. All three Claude Code panes captured full content at `pane_in_mode=0`. The real variable is `alternate_on`: under an alt screen, `-S -N` reads the *normal* screen's stale scrollback. Capture with `-p -J` and no `-S`. See §3.3. **[verified]**
3. **Session groups** — `t2q` reports `grouped=1 group=t2q`; grouped sessions share windows, so one pane appears under several session names and naively-keyed tiles duplicate. Dedupe on `pane_id`. See §2.1. **[group verified; duplication latent — `session_group_size=1` today]**
4. **Pi often reports `cmd=zsh`** — 2 of 3 Pi panes have `pane_current_command=zsh`, not `node`. Title is the strong signal. See §2. **[verified]**
5. **Claude Code's `pane_current_command` is a version string** — observed as `2.1.222`, `2.1.226`, `2.1.228` simultaneously across panes. Unusable as a stable matcher. **[verified]**
6. **Control mode streams `%output` per pane, scoped to the attached session** — the basis for §3.2. Requires stdin held open or the client exits immediately with `%exit`. **[verified]**
7. **A control client does not resize the session** under `window-size=latest` (the server default here); pass `-f ignore-size` anyway so `window-size=smallest` configurations are safe. **[verified for `latest`; assumed for `smallest`]**
8. **`tmux attach -t 'session:window.pane'` accepts a pane target** and selects it (`%window-pane-changed @25 %68`). But use `select-window`/`select-pane` to focus an *existing* client — `attach` adds a second one. See §4. **[verified]**
9. **`tmux` is not on a fixed path** — only `/opt/homebrew/bin/tmux` exists here, and the user's interactive `tmux` is a zsh plugin alias that fails to resolve non-interactively. Resolve explicitly; never shell out to a bare `tmux`. **[verified]**
10. **Nested tmux** — user runs tmux inside tmux (qtc-auto → t2q); the inner server's panes are invisible to the outer one. See §3.4. **[assumed]**
11. **Terminal detection** — Ghostty and iTerm both support tmux attach; clients differ by TTY. **[assumed]**
12. **Ghostty launch** — `open -a Ghostty --args -e tmux attach -t "session:window"`, or osascript `do script`. **[assumed]**
13. **iTerm launch** — osascript to create a window and write the command. **[assumed]**

### Sample tmux commands for reference
```bash
# Whole topology in ONE spawn — do not walk sessions → windows → panes
tmux list-panes -a -F '#{pane_id}|#{session_name}|#{window_index}|#{pane_index}|#{pane_current_command}|#{pane_title}|#{pane_pid}|#{pane_tty}|#{alternate_on}'

tmux list-sessions                         # groups appear as "(group <name>)"
tmux list-clients -F '#{client_tty} #{client_session}'   # who is attached where

tmux capture-pane -t %51 -p -J             # visible screen — NO -S (see §3.3)
tmux -C attach -t <session> -f read-only,ignore-size     # %output event stream (§3.2)

tmux select-window -t '<session>:<window_index>'         # focus existing client
tmux select-pane   -t %51
tmux attach -t '<session>:<window_index>.<pane_index>'   # NEW client only
```

### Agent detection patterns
- **Pi:** title starts with `π ` (usually `π - <project>`); `pane_current_command` is `zsh` *or* `node` — do not rely on it. Prompt line shows `ctx 47.6k (37%)` when idle.
- **Claude Code:** title starts with `✳ ` (e.g. `✳ Investigate JIRA bug BZS-19252`); `pane_current_command` is the release version (`2.1.228`) — corroborating only. Status line shows `ctx 111.5k (11%)`, model name, and `⏵⏵ auto mode on`.
- **Not an agent:** `pane_title` equal to the hostname (`LMYG2LW3F`) — tmux's default when nothing set a title.

## Phases

### Phase 1 — MVP (Core monitoring)
- Menu bar app with vertical floating bar
- Single-call pane discovery (§2), keyed on `pane_id`, deduped across session groups (§2.1)
- Title-first agent detection with descendant-process fallback (§2)
- `ActivitySource` protocol seam + `PollingActivitySource` (§3.1) — green/grey status
- Click to open new terminal with tmux attach (§4, path 2)

**The seam is the load-bearing part of Phase 1.** The polling source is ~20 lines and disposable; what must be right is that nothing above `ActivitySource` knows how activity is detected, so §3.2 drops in without touching the UI or model.

### Phase 2 — Event-driven activity + focus management
- `ControlModeActivitySource` (§3.2): supervised per-session control-client pool, `%output` → timestamp
- Reconnect on `%exit`, survive tmux server restart with backoff
- Detect existing tmux clients via `list-clients`
- Focus existing terminal window with `select-window`/`select-pane` + app activation (requires Accessibility)
- Handle both Ghostty and iTerm

*Sequenced together deliberately: both halves need the same `client_tty` → terminal-app mapping, and both are the payoff for Phase 1's seam.*

### Phase 3 — Rich UI
- Animated fade transitions
- Task name display
- Hover tooltips with session details
- Configurable tile sizes and probe intervals

### Phase 4 — Advanced features
- Notifications on agent completion/failure
- Quick search/filter sessions
- Keyboard shortcuts
- Multiple monitor support
