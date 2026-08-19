import Foundation

/// The single ordered registry of every `TerminalAppProfile` — the one place that answers
/// "which app owns this basename," "what does this app's focus-script/open-new mechanism look
/// like," and "what's the default (and preference-resolved) open-new target."
/// `TTYOwnerResolver.matchTerminalApp`, `SwitchActionPlanner.focusScript`,
/// `SwitchInvocation.openNewAction`, and `HoverPreviewController.resolveOpenNewPreferredApp`
/// all query this instead of switching over `SupportedTerminalApp` cases independently —
/// ADR-0003, TASK-021, and `resolveOpenNewApp` below (whole-branch review finding: TASK-021
/// left `HoverPreviewController`'s own exhaustive switch in place). `SupportedTerminalApp`
/// itself stays a small identity enum; `profile(for:)` is the sole remaining exhaustive switch
/// over it.
public enum TerminalAppCatalog {
    /// Ghostty's scripting dictionary (`Ghostty.sdef`) exposes no `tty` property on its
    /// `terminal` class, so unlike iTerm2/Terminal.app there's no exact identifier to search
    /// by. It does expose a `focus` command that brings a specific `terminal`'s window/tab to
    /// front plus `name` (the tab's title) and `working directory` on each terminal. Best-effort
    /// match, in order (`ghosttyFocusScript`): 1) `name` equals `"tmux attach -t <session>"`,
    /// `"tmux new-session -s <session>"`, or `"tmux new-session -A -s <session>"` — whichever
    /// launch command actually opened the tab is exactly what it's titled, frozen there (this
    /// environment does not do tmux's own dynamic title-setting, TASK-038 — live-confirmed);
    /// 2) `working directory` equals the pane's own `pane_current_path`, or — TASK-038 — an
    /// alternate candidate with a home-relative symlink prefix swapped back in
    /// (`symlinkAliasedCandidatePath`), for when the shell's actual `$PWD` never resolved
    /// through a symlink tmux's canonical path already resolved past. Neither working-directory
    /// candidate is unique when multiple panes share a cwd (picks whichever terminal Ghostty's
    /// `first` returns). `activate` always runs first, unconditionally — `focus` alone only
    /// switches the target window/tab *within* Ghostty's own window ordering; it does not raise
    /// the app above other apps' windows when Ghostty isn't already frontmost. When no match
    /// clause finds a terminal, `activate` alone still surfaces the app.
    public static let ghostty = TerminalAppProfile(
        processBasenames: ["ghostty"],
        makeApp: { .ghostty(pid: $0) },
        focusScript: { target, tty in ghosttyFocusScript(sessionName: target.sessionName, currentPath: target.currentPath, tty: tty) },
        openNewAction: { tmuxPath, paneId in
            // `-n`: force a new instance. Without it, `open -a Ghostty --args ...` silently
            // activates Ghostty's already-running instance and drops `--args` entirely once
            // one is already running — the common case on a dev machine — so no new
            // window/attach ever happens (verified live, TASK-020's Implementation notes).
            .launchProcess(
                executable: "/usr/bin/open",
                arguments: ["-n", "-a", "Ghostty", "--args", "-e", tmuxPath, "attach", "-t", paneId]
            )
        },
        requiresOpenNewAvailabilityCheck: true
    )

    /// iTerm2's `session` class exposes a read-only `tty` property (`iTerm2.sdef`), and
    /// `window`/`tab`/`session` each respond to the `select` command — so the exact session
    /// matching the target tty can be found and selected directly.
    public static let iTerm2 = TerminalAppProfile(
        processBasenames: ["iterm2"],
        makeApp: { .iTerm2(pid: $0) },
        focusScript: { _, tty in iTerm2FocusScript(tty: tty) },
        openNewAction: { tmuxPath, paneId in
            .runScript("""
                tell application "iTerm2"
                    activate
                    create window with default profile command "\(tmuxPath) attach -t \(paneId)"
                end tell
                """)
        }
    )

    /// Terminal.app's `tab` class exposes a read-only `tty` property and a settable `selected`
    /// property (`Terminal.sdef`); its `window` class exposes a settable `frontmost` property.
    public static let terminalApp = TerminalAppProfile(
        processBasenames: ["terminal"],
        makeApp: { .terminalApp(pid: $0) },
        focusScript: { _, tty in terminalAppFocusScript(tty: tty) },
        openNewAction: { tmuxPath, paneId in
            .runScript("""
                tell application "Terminal"
                    activate
                    do script "\(tmuxPath) attach -t \(paneId)"
                end tell
                """)
        }
    )

    /// Cursor ships no `.sdef` scripting dictionary at all (live-verified against the installed
    /// Cursor.app — feature spec Further Notes), so unlike the other three profiles there's no
    /// tab/window-level selection available; `activate` is the only usable verb. Its executable
    /// basename never appears directly in the ancestor chain from a tmux client's tty — the
    /// match instead fires one hop up, at `Cursor Helper: terminal pty-host`, whose `command`
    /// field's first whitespace-separated token is `Cursor` (live-verified, `ps -o command=`
    /// against a real Cursor-integrated-terminal tty). `openNewAction` is left `nil`: no
    /// scriptable way to launch a new attached terminal inside Cursor's integrated terminal;
    /// `SwitchInvocation.openNewAction` falls through to the default open-new target for that.
    public static let cursor = TerminalAppProfile(
        processBasenames: ["cursor"],
        makeApp: { .cursor(pid: $0) },
        focusScript: { _, tty in cursorFocusScript(tty: tty) }
    )

    public static let all: [TerminalAppProfile] = [ghostty, iTerm2, terminalApp, cursor]

    /// Used by `TTYOwnerResolver`'s ancestor-walk matcher: which profile (if any) recognizes
    /// this executable basename.
    public static func match(basename: String) -> TerminalAppProfile? {
        all.first { $0.processBasenames.contains(basename) }
    }

    /// The sole remaining exhaustive switch over `SupportedTerminalApp` — every other consumer
    /// queries the catalog instead of switching independently.
    public static func profile(for app: SupportedTerminalApp) -> TerminalAppProfile {
        switch app {
        case .ghostty: return ghostty
        case .iTerm2: return iTerm2
        case .terminalApp: return terminalApp
        case .cursor: return cursor
        }
    }

    /// Ghostty-if-available-else-Terminal.app — the default open-new target when there's no
    /// (or an unavailable) preferred app. `isGhosttyAvailable` is injected rather than checked
    /// here directly: the real check is an `NSWorkspace` bundle-identifier lookup, and
    /// `TmuxCore` stays free of AppKit so it tests headlessly (CLAUDE.md) — the AppKit-backed
    /// check lives at `HoverPreviewController`'s call site.
    public static func defaultOpenNewApp(isGhosttyAvailable: () -> Bool) -> SupportedTerminalApp {
        isGhosttyAvailable() ? .ghostty(pid: -1) : .terminalApp(pid: -1)
    }

    /// Resolves which app `SwitchInvocation.openNewAction` should actually target, given a
    /// caller's preferred app (if any). Falls back to `defaultOpenNewApp(isGhosttyAvailable:)`
    /// when `preferred` is `nil`, when its profile has no `openNewAction` at all (Cursor,
    /// TASK-022), or when its profile demands re-validating availability before use
    /// (`requiresOpenNewAvailabilityCheck` — Ghostty); otherwise `preferred` passes through
    /// unchanged. This is what `HoverPreviewController.resolveOpenNewPreferredApp` used to
    /// compute via its own exhaustive switch over `SupportedTerminalApp` (whole-branch review
    /// finding) — moving it here means a fifth app costs exactly the profile entry `all`
    /// already requires, same as ADR-0003 promises for `profile(for:)`.
    public static func resolveOpenNewApp(
        preferred: SupportedTerminalApp?,
        isGhosttyAvailable: () -> Bool
    ) -> SupportedTerminalApp {
        guard let preferred else {
            return defaultOpenNewApp(isGhosttyAvailable: isGhosttyAvailable)
        }
        let candidate = profile(for: preferred)
        guard candidate.openNewAction != nil, !candidate.requiresOpenNewAvailabilityCheck else {
            return defaultOpenNewApp(isGhosttyAvailable: isGhosttyAvailable)
        }
        return preferred
    }

    /// `homeDirectory`/`homeChildren`/`resolveSymlink` default to real filesystem queries —
    /// injected only so tests can override them without touching the real `$HOME`
    /// (`symlinkAliasedCandidatePath`'s doc comment). Non-`private` for the same reason:
    /// `TerminalAppCatalogTests` calls this directly with fake filesystem closures to prove the
    /// symlink-aliased working-directory candidate is actually wired into the script, not just
    /// computed correctly in isolation.
    static func ghosttyFocusScript(
        sessionName: String,
        currentPath: String,
        tty: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        homeChildren: (String) -> [String] = { home in (try? FileManager.default.contentsOfDirectory(atPath: home)) ?? [] },
        resolveSymlink: (String) -> String? = { path in
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil else { return nil }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        }
    ) -> String {
        // TASK-038: a tab's title is frozen at whichever launch command actually opened it
        // (live-confirmed this environment does not do tmux's dynamic title-setting) — an
        // `attach`-opened tab and a `new-session`/`new-session -A`-opened tab for the same
        // session end up titled differently, so all three launch forms need their own title
        // candidate, tried in this order before falling through to the working-directory match.
        let titleCandidates = [
            "tmux attach -t \(sessionName)",
            "tmux new-session -s \(sessionName)",
            "tmux new-session -A -s \(sessionName)"
        ]

        // The canonical `pane_current_path` is always tried first; a symlink-aliased path (if
        // one resolves) is an *additional* candidate appended after it, never a replacement.
        var pathCandidates = [currentPath]
        if let aliasedPath = symlinkAliasedCandidatePath(
            for: currentPath,
            homeDirectory: homeDirectory,
            homeChildren: homeChildren,
            resolveSymlink: resolveSymlink
        ) {
            pathCandidates.append(aliasedPath)
        }

        let branches = (
            titleCandidates.map { appleScriptBranch(property: "name", rawValue: $0) }
                + pathCandidates.map { appleScriptBranch(property: "working directory", rawValue: $0) }
        ).joined(separator: "\n    else if ")

        return """
        -- target tty: \(tty)
        tell application "Ghostty"
            activate
            if \(branches)
            end if
        end tell
        """
    }

    /// One `exists (...) then\n  focus (...)`-shaped AppleScript clause matching a Ghostty
    /// `terminal`'s `property` against `rawValue` — shared by `ghosttyFocusScript`'s title and
    /// working-directory candidates so every candidate renders identically and is escaped
    /// exactly once.
    private static func appleScriptBranch(property: String, rawValue: String) -> String {
        let match = "\"\(escapeForAppleScript(rawValue))\""
        return "exists (first terminal whose \(property) is \(match)) then\n        focus (first terminal whose \(property) is \(match))"
    }

    /// Generates an *additional* Ghostty working-directory candidate for a pane's canonical
    /// `currentPath` when it lives behind a home-relative symlink alias (e.g. `~/widgets` ->
    /// `~/Work/Projects/widgets`, TASK-038 — live-diagnosed via `osascript`: Ghostty's own
    /// `working directory` property reports the shell's actual `$PWD`, which stays unresolved
    /// through a symlinked `cd`, while tmux's `pane_current_path` always reports the canonical,
    /// fully-resolved path). Enumerates `homeChildren(homeDirectory)`, resolves each with
    /// `resolveSymlink` (`nil` when a child isn't a symlink), and — where `currentPath`'s path
    /// components start with a resolved target's — returns `currentPath` with that prefix
    /// swapped back to the symlink's own (home-relative) name. Component-wise, not a raw string
    /// prefix: `.../widgets` must not match `.../widgetsextra/repo`. Small and pure — home
    /// listing and symlink resolution are both injected (mirrors `TmuxCore.resolveTmuxPath`'s
    /// injectable `isExecutableFile`) — so it's unit-testable without touching the real `$HOME`.
    static func symlinkAliasedCandidatePath(
        for currentPath: String,
        homeDirectory: String,
        homeChildren: (String) -> [String],
        resolveSymlink: (String) -> String?
    ) -> String? {
        let currentComponents = (currentPath as NSString).pathComponents
        for child in homeChildren(homeDirectory) {
            let childPath = (homeDirectory as NSString).appendingPathComponent(child)
            guard let resolved = resolveSymlink(childPath) else { continue }
            let resolvedComponents = (resolved as NSString).pathComponents
            guard currentComponents.count >= resolvedComponents.count,
                  Array(currentComponents.prefix(resolvedComponents.count)) == resolvedComponents else {
                continue
            }
            let suffixComponents = Array(currentComponents.dropFirst(resolvedComponents.count))
            return NSString.path(withComponents: (childPath as NSString).pathComponents + suffixComponents)
        }
        return nil
    }

    /// Escapes a value for embedding inside an AppleScript double-quoted string literal —
    /// backslash first (so it doesn't double-escape the quote escaping that follows), then `"`.
    private static func escapeForAppleScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func iTerm2FocusScript(tty: String) -> String {
        """
        tell application "iTerm2"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                            select w
                            select t
                            select s
                            return
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        """
    }

    /// Cursor has no scripting dictionary at all (see `cursor`'s doc comment above) —
    /// `activate` is the only verb available, so unlike the other three profiles there's no
    /// tab/window-level selection to build. `tty` isn't a match key here (nothing to match
    /// against), but is embedded as a comment anyway — same traceability role it plays in
    /// `ghosttyFocusScript`'s leading comment, and it keeps this profile's script
    /// distinguishable per-target the same way the other three are.
    private static func cursorFocusScript(tty: String) -> String {
        """
        -- target tty: \(tty)
        tell application "Cursor"
            activate
        end tell
        """
    }

    private static func terminalAppFocusScript(tty: String) -> String {
        """
        tell application "Terminal"
            activate
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(tty)" then
                        set selected of t to true
                        set frontmost of w to true
                        return
                    end if
                end repeat
            end repeat
        end tell
        """
    }
}
