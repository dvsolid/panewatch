import Foundation

/// One of the three terminal apps `TTYOwnerResolver` knows how to recognize, carrying the pid
/// of the matched ancestor process — feature spec § Architecture: TTYOwnerResolver.
public enum SupportedTerminalApp: Sendable, Equatable {
    case ghostty(pid: Int32)
    case iTerm2(pid: Int32)
    case terminalApp(pid: Int32)
}

/// Resolves which of the three supported terminal apps (if any) owns a given tty, by snapshotting
/// the process table and walking *upward* from the process(es) attached to that tty — the
/// ancestor-walk mirror of `DescendantProcessInspector`'s downward walk. Used by Switch (TASK-018)
/// to decide whether a pane's attached tmux client has an existing terminal window that can be
/// focused, versus falling back to opening a new one.
public protocol TTYOwnerResolver: Sendable {
    func resolveOwningApp(tty: String) -> SupportedTerminalApp?
}

/// The live `TTYOwnerResolver`: snapshots the whole process table via
/// `ps -A -o pid=,ppid=,tty=,command=` and walks ancestors of the process(es) attached to `tty`
/// within it. Its own snapshot, independent of `ProcessTableDescendantInspector`'s (feature spec:
/// "no shared refactor of the existing descendant-walk snapshot format is in scope here").
public struct ProcessTableTTYOwnerResolver: TTYOwnerResolver {
    private let psExecutableURL: URL

    public init() {
        self.init(psExecutableURL: URL(fileURLWithPath: "/bin/ps"))
    }

    /// Test seam: point at a fake `ps`-shaped executable instead of the real `/bin/ps` — same
    /// pattern as `ProcessTableDescendantInspector.psExecutableURL`.
    init(psExecutableURL: URL) {
        self.psExecutableURL = psExecutableURL
    }

    public func resolveOwningApp(tty: String) -> SupportedTerminalApp? {
        guard let table = try? Self.snapshotProcessTable(psExecutableURL: psExecutableURL), !table.isEmpty else {
            return nil
        }

        var byPID: [Int32: ProcessEntry] = [:]
        for entry in table { byPID[entry.pid] = entry }

        let normalizedTTY = Self.normalize(tty: tty)
        let owningPIDs = table.filter { $0.tty == normalizedTTY }.map(\.pid)

        for startPID in owningPIDs {
            var pid: Int32? = startPID
            var visited = Set<Int32>()
            while let currentPID = pid, visited.insert(currentPID).inserted {
                guard let entry = byPID[currentPID] else { break }
                if let app = Self.matchTerminalApp(command: entry.command, pid: entry.pid) {
                    return app
                }
                pid = entry.ppid
            }
        }
        return nil
    }

    private struct ProcessEntry {
        let pid: Int32
        let ppid: Int32
        let tty: String
        let command: String
    }

    struct SnapshotFailed: Error {
        let terminationStatus: Int32
    }

    /// Executable-basename markers, mirroring `AgentDetector.agentProcessNames`'s discipline:
    /// basename equality against the process's own executable path, not substring containment.
    private static func matchTerminalApp(command: String, pid: Int32) -> SupportedTerminalApp? {
        let executablePath = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? command
        let basename = (executablePath as NSString).lastPathComponent.lowercased()
        switch basename {
        case "ghostty": return .ghostty(pid: pid)
        case "iterm2": return .iTerm2(pid: pid)
        case "terminal": return .terminalApp(pid: pid)
        default: return nil
        }
    }

    /// `list-clients`/`ClientInfo.tty` carries tmux's `/dev/ttysNNN` form; `ps -o tty=` reports
    /// the bare `ttysNNN` form. Strip the prefix so both line up.
    private static func normalize(tty: String) -> String {
        tty.hasPrefix("/dev/") ? String(tty.dropFirst("/dev/".count)) : tty
    }

    /// Parses `ps -A -o pid=,ppid=,tty=,command=` output: four whitespace-separated fields per
    /// line (`tty` never contains whitespace, so it's safe as the third fixed field), `command`
    /// potentially containing further whitespace (hence `maxSplits: 3`).
    private static func snapshotProcessTable(psExecutableURL: URL) throws -> [ProcessEntry] {
        let process = Process()
        process.executableURL = psExecutableURL
        process.arguments = ["-A", "-o", "pid=,ppid=,tty=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SnapshotFailed(terminationStatus: process.terminationStatus)
        }
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else {
                return nil
            }
            return ProcessEntry(pid: pid, ppid: ppid, tty: String(parts[2]), command: String(parts[3]))
        }
    }
}
