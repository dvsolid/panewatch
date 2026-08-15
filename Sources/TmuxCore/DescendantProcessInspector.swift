import Foundation

/// Supplies descendant-process argv for `AgentDetector`'s ladder step 2 (SPEC §2: "walk
/// children of pane_pid and match on argv"). Kept separate from the matching logic itself —
/// analogous to `TmuxGateway` — so tests inject canned argv instead of walking a real process
/// tree (TASK-004 Test seam: "no real process tree walked in tests").
public protocol DescendantProcessInspector: Sendable {
    /// Returns the command line of every process descended from each `pid` in `pids`, at any
    /// depth (not just direct children). Order within a pid's array is unspecified —
    /// `AgentDetector` matches each entry independently and stops at the first hit.
    ///
    /// A pid present in the result (even with an empty array) means the walk ran and found no
    /// agent descendant; a pid *absent* from the result means the walk could not run at all
    /// (e.g. the underlying process-table snapshot failed) — callers must not cache the former
    /// interpretation for the latter case, or a single failed snapshot permanently misclassifies
    /// every pane in that pass.
    ///
    /// Takes the whole batch of pids needing a walk in one call, not one call per pid: the
    /// concrete process-table snapshot this is built on is a single `ps -A` spawn regardless of
    /// how many pids are asked about, so batching collapses N spawns per discovery pass to 1
    /// (TASK-004 measured ~50ms warm / 114ms cold per spawn).
    func descendantArgv(of pids: Set<Int32>) -> [Int32: [String]]
}

/// The live `DescendantProcessInspector`: snapshots the whole process table via
/// `ps -A -o pid=,ppid=,command=` and walks descendants of each requested pid within it. No
/// Accessibility permission required — this feature requests none (feature spec §
/// Implementation decisions).
///
/// One `ps` spawn per call, regardless of how many pids are in the batch — this is SPEC §2's
/// "only expensive step" in the detection ladder. `AgentDetector` caches the fallback ladder
/// step's result per `pane_id` so a given pane only ever pays for *that* resolution once (SPEC
/// §2: "run it once per newly-seen pane_id and cache the result for the pane's lifetime") — but
/// title-match corroboration (TASK-013) is deliberately uncached, since it re-checks whether an
/// already-classified agent is still alive, not whether a shell wraps one. Either way, every pid
/// needing a walk this pass — cached-fallback-eligible or not — batches into one call.
public struct ProcessTableDescendantInspector: DescendantProcessInspector {
    private let psExecutableURL: URL

    public init() {
        self.init(psExecutableURL: URL(fileURLWithPath: "/bin/ps"))
    }

    /// Test seam: point at a fake `ps`-shaped executable instead of the real `/bin/ps` — same
    /// pattern as `ProcessTmuxGateway.tmuxPath` (CLAUDE.md: "shell out through an injectable
    /// command runner so the real binary can be faked"). Lets tests exercise the non-zero-exit
    /// and empty-output failure paths in `snapshotProcessTable()` without depending on `/bin/ps`
    /// itself ever failing.
    init(psExecutableURL: URL) {
        self.psExecutableURL = psExecutableURL
    }

    public func descendantArgv(of pids: Set<Int32>) -> [Int32: [String]] {
        guard !pids.isEmpty else { return [:] }
        guard let table = try? Self.snapshotProcessTable(psExecutableURL: psExecutableURL), !table.isEmpty else { return [:] }

        var childrenByParent: [Int32: [Int32]] = [:]
        var commandByPID: [Int32: String] = [:]
        for entry in table {
            childrenByParent[entry.ppid, default: []].append(entry.pid)
            commandByPID[entry.pid] = entry.command
        }

        var results: [Int32: [String]] = [:]
        for pid in pids {
            var result: [String] = []
            var frontier = childrenByParent[pid] ?? []
            var visited = Set<Int32>()
            while let next = frontier.popLast() {
                guard visited.insert(next).inserted else { continue }
                if let command = commandByPID[next] { result.append(command) }
                frontier.append(contentsOf: childrenByParent[next] ?? [])
            }
            results[pid] = result
        }
        return results
    }

    private struct ProcessEntry {
        let pid: Int32
        let ppid: Int32
        let command: String
    }

    struct SnapshotFailed: Error {
        let terminationStatus: Int32
    }

    /// Parses `ps -A -o pid=,ppid=,command=` output: three whitespace-separated fields per
    /// line, `command` potentially containing further whitespace (hence `maxSplits: 2`).
    ///
    /// Throws on a non-zero exit rather than trusting whatever landed on stdout: a spawn that
    /// runs but is killed, denied by the sandbox/seatbelt, or otherwise fails partway through
    /// can still leave parsable-but-wrong output on the pipe. Checking `terminationStatus` is
    /// what lets `descendantArgv(of:)` distinguish "the walk ran and found nothing" from "the
    /// walk didn't really run" — see this file's `DescendantProcessInspector` doc comment.
    private static func snapshotProcessTable(psExecutableURL: URL) throws -> [ProcessEntry] {
        let process = Process()
        process.executableURL = psExecutableURL
        process.arguments = ["-A", "-o", "pid=,ppid=,command="]
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
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else {
                return nil
            }
            return ProcessEntry(pid: pid, ppid: ppid, command: String(parts[2]))
        }
    }
}
