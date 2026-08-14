import Foundation

/// Supplies descendant-process argv for `AgentDetector`'s ladder step 2 (SPEC §2: "walk
/// children of pane_pid and match on argv"). Kept separate from the matching logic itself —
/// analogous to `TmuxGateway` — so tests inject canned argv instead of walking a real process
/// tree (TASK-004 Test seam: "no real process tree walked in tests").
public protocol DescendantProcessInspector: Sendable {
    /// Returns the command line of every process descended from `pid`, at any depth (not just
    /// direct children). Order is unspecified — `AgentDetector` matches each entry
    /// independently and stops at the first hit.
    func descendantArgv(of pid: Int32) -> [String]
}

/// The live `DescendantProcessInspector`: snapshots the whole process table via
/// `ps -A -o pid=,ppid=,command=` and walks descendants of `pid` within it. No Accessibility
/// permission required — this feature requests none (feature spec § Implementation decisions).
///
/// One `ps` spawn per call. This is SPEC §2's "only expensive step" in the detection ladder;
/// `AgentDetector` caches results per `pane_id` so a given pane only ever pays for this once
/// (SPEC §2: "run it once per newly-seen pane_id and cache the result for the pane's
/// lifetime").
public struct ProcessTableDescendantInspector: DescendantProcessInspector {
    public init() {}

    public func descendantArgv(of pid: Int32) -> [String] {
        guard let table = try? Self.snapshotProcessTable() else { return [] }

        var childrenByParent: [Int32: [Int32]] = [:]
        var commandByPID: [Int32: String] = [:]
        for entry in table {
            childrenByParent[entry.ppid, default: []].append(entry.pid)
            commandByPID[entry.pid] = entry.command
        }

        var result: [String] = []
        var frontier = childrenByParent[pid] ?? []
        var visited = Set<Int32>()
        while let next = frontier.popLast() {
            guard visited.insert(next).inserted else { continue }
            if let command = commandByPID[next] { result.append(command) }
            frontier.append(contentsOf: childrenByParent[next] ?? [])
        }
        return result
    }

    private struct ProcessEntry {
        let pid: Int32
        let ppid: Int32
        let command: String
    }

    /// Parses `ps -A -o pid=,ppid=,command=` output: three whitespace-separated fields per
    /// line, `command` potentially containing further whitespace (hence `maxSplits: 2`).
    private static func snapshotProcessTable() throws -> [ProcessEntry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else {
                return nil
            }
            return ProcessEntry(pid: pid, ppid: ppid, command: String(parts[2]))
        }
    }
}
