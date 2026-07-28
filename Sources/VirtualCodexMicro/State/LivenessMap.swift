import Foundation

/// The one answer to "which sessions are alive, and at which pid".
///
/// It exists because there were three answers. `reconcile` asked argv only, the
/// transcript poll asked argv plus hook pids, and the `VCM_PROBE` diagnostic asked
/// argv plus persisted pids — so the probe reported a session the app could not see,
/// and `DriftGuard.evidence`, which *deletes* a liveness-covered session missing from
/// the map, erased a running session before `reconnect` ever saw it. The hydra key
/// read "no live session carries id …" for days while the process was running and its
/// transcript was being appended to.
///
/// Four sources, because no single one covers a bare `claude`:
///
/// 1. **argv** — `--session-id` / `--resume <uuid>`. The only source that works cold,
///    and blind to a session started as plain `claude`.
/// 2. **hook-learned pids** — `CLAUDE_PID` at `SessionStart`. Covers the bare case,
///    but only from the moment the hook fires, and only if it is installed.
/// 3. **persisted pids** — what the registry recorded when the slot was bound.
///    Survives an app restart, which is exactly when the other two are weakest.
/// 4. **working directory** — a bare `claude`'s cwd against the cwd the transcript
///    states. The only source that can adopt a bare session nobody ever told us about.
///
/// Every pid from a remembered source is re-checked with `kill(pid, 0)`: a pid learned
/// at `SessionStart` or read from disk says where a process *was*. Asserting a stale
/// pid is worse than admitting ignorance, because `StateEngine.setLiveness` never
/// expires — a wrong `.alive` outlives the session and a wrong `.dead` poisons it.
enum LivenessMap {
    /// - Parameters:
    ///   - hookPIDs: session id → pid, learned from `CLAUDE_PID`.
    ///   - persistedPIDs: session id → pid, as the registry recorded it.
    ///   - workingDirectories: session id → the cwd its transcript states.
    static func build(
        hookPIDs: [String: Int32],
        persistedPIDs: [String: Int32],
        workingDirectories: [String: String],
        bareProcesses: [String: Int32],
        isAlive: (Int32) -> Bool
    ) -> [String: Int32] {
        // 1. argv. Trusted without a liveness check: `ps` only just listed it.
        var map = ClaudeTranscriptSource.liveSessions()

        // 2 and 3. Remembered pids, each re-verified. Hooks before persistence: a hook
        // fires in the session's own lifetime, while a persisted pid can predate a
        // restart of anything.
        for source in [hookPIDs, persistedPIDs] {
            for (id, pid) in source where map[id] == nil {
                if isAlive(pid) { map[id] = pid }
            }
        }

        // 4. The cwd join, last because it is an inference rather than a report: it
        // concludes *which* session a bare process is, where the others are told.
        for (directory, pid) in bareProcesses.sorted(by: { $0.key < $1.key }) {
            // A pid already attributed is not available. Skipping this check let one
            // live pid identify two sessions: the directory held two transcripts, the
            // first was claimed from a persisted pid, and filtering claimed sessions out
            // of the candidate list left the second looking unambiguous — so a dead
            // session was marked alive at a running session's pid.
            guard !map.values.contains(pid) else { continue }
            // Counted over every transcript claiming the directory, not just unclaimed
            // ones, for the same reason: a directory with two histories cannot be
            // resolved from outside, and picking either defeats the `idle`/`complete`
            // gate this map feeds.
            let inDirectory = workingDirectories.filter { $0.value == directory }.map(\.key)
            guard inDirectory.count == 1, let only = inDirectory.first, map[only] == nil
            else { continue }
            map[only] = pid
        }
        return map
    }

    /// Live counterpart. The caller supplies what only it knows; everything else is
    /// read here so the two call sites cannot drift apart again.
    static func current(
        hookPIDs: [String: Int32],
        workingDirectories: [String: String],
        registry: SessionRegistry = SessionRegistry()
    ) -> [String: Int32] {
        var persisted: [String: Int32] = [:]
        for binding in registry.bindings.compactMap({ $0 }) {
            if let pid = binding.pid { persisted[binding.sessionID] = pid }
        }
        return build(
            hookPIDs: hookPIDs,
            persistedPIDs: persisted,
            workingDirectories: workingDirectories,
            bareProcesses: ClaudeTranscriptSource.bareClaudeWorkingDirectories(),
            isAlive: PTYChild.isAlive
        )
    }

    // MARK: - Self check

    static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        // `build` calls the real `liveSessions()`, so every id here is one no live
        // process can carry and the argv contribution is empty by construction.
        let hydra = "0c26cbd8-0000-0000-0000-000000000001"
        let other = "0c26cbd8-0000-0000-0000-000000000002"
        let dir = "/Users/me/code/hydra"

        // The bug: the pid was on disk the whole time and no path consulted it.
        let fromDisk = build(
            hookPIDs: [:], persistedPIDs: [hydra: 3448], workingDirectories: [:],
            bareProcesses: [:], isAlive: { $0 == 3448 }
        )
        check("a persisted pid was ignored", fromDisk[hydra] == 3448)
        check("a persisted pid was trusted without checking it is alive",
              build(hookPIDs: [:], persistedPIDs: [hydra: 3448], workingDirectories: [:],
                    bareProcesses: [:], isAlive: { _ in false })[hydra] == nil)

        // The cwd join adopts a bare process nobody reported.
        let joined = build(
            hookPIDs: [:], persistedPIDs: [:], workingDirectories: [hydra: dir],
            bareProcesses: [dir: 3448], isAlive: { _ in true }
        )
        check("the cwd join did not adopt a bare session", joined[hydra] == 3448)

        // Two sessions in one directory are indistinguishable from outside, so neither
        // is claimed. Marking the wrong one alive would defeat the idle/exited gate.
        let ambiguous = build(
            hookPIDs: [:], persistedPIDs: [:],
            workingDirectories: [hydra: dir, other: dir],
            bareProcesses: [dir: 3448], isAlive: { _ in true }
        )
        check("an ambiguous directory was resolved by guessing",
              ambiguous[hydra] == nil && ambiguous[other] == nil)

        // Found live: one pid handed to two sessions. The directory held two
        // transcripts, the first was claimed from a persisted pid, and that left the
        // second looking unambiguous — so a session that had exited was marked alive
        // at a running session's pid, and would have resolved `idle` instead of
        // abstaining.
        let shared = build(
            hookPIDs: [:], persistedPIDs: [hydra: 3448],
            workingDirectories: [hydra: dir, other: dir],
            bareProcesses: [dir: 3448], isAlive: { _ in true }
        )
        check("one pid was attributed to two sessions", shared[other] == nil)
        check("the session that owns the pid lost it", shared[hydra] == 3448)

        // A hook pid outranks a persisted one: it was observed this session.
        let both = build(
            hookPIDs: [hydra: 111], persistedPIDs: [hydra: 222],
            workingDirectories: [:], bareProcesses: [:], isAlive: { _ in true }
        )
        check("a persisted pid overrode a hook-learned one", both[hydra] == 111)

        // A session already placed is not re-placed by a weaker source.
        let settled = build(
            hookPIDs: [hydra: 111], persistedPIDs: [:], workingDirectories: [hydra: dir],
            bareProcesses: [dir: 999], isAlive: { _ in true }
        )
        check("the cwd join overwrote a reported pid", settled[hydra] == 111)
        return failures
    }
}
