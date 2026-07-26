import Foundation

/// Cold-start and fallback state for Claude Code sessions, inferred by tailing the
/// session transcripts under `~/.claude/projects`. A port of
/// `spikes/tailing/watch.py`, whose rules were measured against 31 transcripts and
/// 12,541 records: 93.0% agreement, 0.9% wrong, 6.1% abstained, detection within
/// one poll interval (max 0.231s at 200ms).
///
/// **Why this exists at all.** Hooks are edge-triggered: no snapshot, no query. A
/// panel opening mid-session learns nothing from them until the next transition, so
/// this is the only way to populate six keys at launch, and the only route to
/// sessions that started before the hooks were installed.
///
/// **What it cannot see.** A pending permission prompt writes no transcript record
/// at all — a `Bash` call that ran 100 minutes and an approval prompt that sat open
/// 145 minutes produce byte-identical tails. So this source never reports
/// `.needsInput`, which is exactly what `StateSource.claudeTranscript` declares by
/// omitting it. The `AskUserQuestion` exception the spike could technically infer is
/// deliberately dropped (task 022): a source that catches one tool in ten is worse
/// than one that says it cannot see the state. Amber comes from hooks or not at all.
///
/// **What it can see, and nothing else can.** The *end* of a prompt, on the reject
/// path. Rejecting a permission prompt emits no hook event whatsoever — witnessed in
/// `spikes/needsinput`, both reject affordances, no `PermissionDenied`, no `Stop`, no
/// `PostToolUseFailure` and no `Notification` after 170 s idle — so
/// `PermissionRequest` turns a key amber and the hook stream has nothing left to say.
/// The transcript does record it, so `Reading.promptClearedAt` carries that one fact.
/// It is deliberately **not** a state: reporting the end of a prompt does not require
/// the vocabulary to report its beginning, and this source must never have the
/// latter. See `StateEngine.clearNeedsInput`.
///
/// Read-only on `~/.claude`. Nothing here opens a file for writing.
///
/// Two ceilings carried over from the spike, both deliberate:
///
/// - ponytail: cold start reads only the last `tailWindow` bytes. A `tool_use` older
///   than that loses its `tool_result` pairing (21 of the spike's 118 wrong
///   observations). Raise the window, or index the whole file, if sessions with
///   multi-megabyte single turns turn out to be common.
/// - ponytail: `poll()` re-reads from a stored offset on a timer instead of using
///   FSEvents. 31 files at 200ms is ~150 syscalls/second, noise on any Mac, and it
///   met the sub-1s criterion with margin. Swap in `FSEventStreamCreate` if the file
///   count reaches the hundreds or the interval needs to drop below ~50ms.
public struct ClaudeTranscriptSource: Sendable {
    /// The vocabulary and staleness window this adapter feeds readings under.
    /// `.error` is inside `reportableStates` but this source never produces it: 5
    /// records in 12,541, erased by the CLI's next retry, and a `tool_result` with
    /// `is_error: true` is *not* one of them (40 routine occurrences). Painting keys
    /// red on that evidence is worse than staying grey, so an API-error tail
    /// abstains and hooks own `error`.
    public static let source = StateSource.claudeTranscript

    public static let defaultProjectsDirectory = FileManager.default
        .homeDirectoryForCurrentUser
        .appending(path: ".claude/projects")

    public let projectsDirectory: URL

    /// Silence after which a mid-turn tail stops meaning `running` and a turn
    /// boundary starts meaning `idle` rather than `complete`.
    ///
    /// 60s is the spike's measured default: within-turn silence is p50 2.2s, p90
    /// 10.8s, p99 74s, max 8713s, so 1.2% of busy turns get greyed and the wrong
    /// rate is 0.9% at every value tried (20s → 120s). The cost lands on abstention,
    /// which is the safe direction. It must stay *below*
    /// `source.stalenessThreshold`: `idle` is only produced once the session is
    /// quiet, so if the two were equal the engine would expire every `idle` reading
    /// the moment this source became willing to make one. `selfCheckFailures()`
    /// enforces that.
    public let quietAfter: TimeInterval

    private var cursors: [String: Cursor] = [:]

    /// 1MB. See the type comment: a `tool_use` older than this loses its pairing.
    private static let tailWindow: UInt64 = 1 << 20
    /// Records retained per session after a poll. Deeper than any observed turn, and
    /// forgetting an ancient `tool_use` only ever loses a `running` reading — it
    /// cannot invent one.
    private static let keptRecords = 80

    public init(
        projectsDirectory: URL = ClaudeTranscriptSource.defaultProjectsDirectory,
        quietAfter: TimeInterval = 60
    ) {
        self.projectsDirectory = projectsDirectory
        self.quietAfter = quietAfter
    }

    // MARK: - Output

    /// One session's state as the transcript reveals it, plus the `ps` join.
    public struct Reading: Sendable, Equatable {
        /// The id a live process carries in argv: the newest `session_id` stamped
        /// inside the file, falling back to the filename. Not necessarily the
        /// filename — see `candidateIDs` in `sessionIDs(...)`.
        public let sessionID: String
        public let transcriptPath: String
        public let state: AgentState
        /// When the *evidence* was produced — the newest timestamped record in the
        /// tail, never the poll time. `StateEngine`'s staleness window measures from
        /// this, so "quiet" has to mean the session was quiet rather than that our
        /// poller was.
        public let observedAt: Date
        public let liveness: Liveness
        public let pid: Int32?
        /// When the tail last witnessed a pending permission prompt **stop** being
        /// pending — a rejection, or an interrupt. `nil` for the overwhelming
        /// majority of readings, which is the normal case.
        ///
        /// Not a state, and not expressible as one here on purpose: `needsInput` is
        /// outside this source's declared vocabulary and this does not sneak it back
        /// in. It can only ever take amber down, never light it. `StateEngine`'s
        /// `clearNeedsInput` is the other half.
        public let promptClearedAt: Date?
        /// Why this state, in words, for the tooltip and the log. Structural facts
        /// only: no prompt text, no tool names, no paths from inside the transcript.
        public let reason: String
    }

    /// Every session with a transcript on disk, oldest evidence and all. Pass
    /// `liveSessions:` to pin the `ps` join (the self-check does; live callers should
    /// let it default so the join actually runs).
    ///
    /// `mutating` because the per-file read offsets live in the value: a cold start
    /// reads the last megabyte, every poll after that reads only what was appended.
    public mutating func poll(
        now: Date = Date(),
        liveSessions live: [String: Int32]? = nil
    ) -> [Reading] {
        let live = live ?? Self.liveSessions()
        var readings: [Reading] = []
        var present = Set<String>()

        for url in Self.transcripts(in: projectsDirectory) {
            let key = url.path
            present.insert(key)
            var cursor = cursors[key] ?? Cursor()
            if let (new, offset) = Self.readTail(url, from: cursor.offset) {
                cursor.offset = offset
                if !new.isEmpty {
                    cursor.records = Array((cursor.records + new).suffix(Self.keptRecords))
                }
            }
            cursors[key] = cursor

            let ids = Self.sessionIDs(cursor.records, path: url)
            let pid = ids.candidates.compactMap { live[$0] }.first
            var (state, observedAt, reason) = Self.infer(cursor.records, quietAfter: quietAfter, now: now)

            // The `ps` join, and the one place it changes a reading. `idle` and
            // `complete` both say "the turn is over", which is also what a graceful
            // quit, a Ctrl-C and a crash leave behind — there is no session-exit
            // record of any kind, and `lsof` shows nothing because the CLI appends
            // and closes. Without a matching process those readings are guesses, so
            // they abstain.
            //
            // `running` is not gated: the file grew inside `quietAfter`, which is
            // positive evidence something was alive seconds ago. And liveness stays
            // `.unknown` rather than `.dead` on a miss — the process must have been
            // launched with `--session-id` to be visible here at all, and
            // `StateEngine.setLiveness` never expires, so a wrong `.dead` would
            // poison the session for the rest of the run.
            if pid == nil, state == .idle || state == .complete {
                state = .unknown
                reason += "; no live process carries this session id, so idle and exited are indistinguishable"
            }

            readings.append(Reading(
                sessionID: ids.display,
                transcriptPath: key,
                state: state,
                observedAt: observedAt,
                liveness: pid == nil ? .unknown : .alive,
                pid: pid,
                promptClearedAt: Self.promptCleared(in: cursor.records),
                reason: reason
            ))
        }

        // A deleted transcript must not keep its offset around.
        cursors = cursors.filter { present.contains($0.key) }
        return readings.sorted { ($0.sessionID, $0.transcriptPath) < ($1.sessionID, $1.transcriptPath) }
    }

    /// Polls forever, yielding the full set of readings whenever any session's
    /// state, evidence time or liveness changes. 200ms is measured sufficient
    /// (min 0.018s, p50 0.146s, max 0.231s detection); `ps` runs every tenth tick,
    /// matching the spike's 2s liveness cadence.
    public static func updates(
        projectsDirectory: URL = ClaudeTranscriptSource.defaultProjectsDirectory,
        quietAfter: TimeInterval = 60,
        interval: Duration = .milliseconds(200)
    ) -> AsyncStream<[Reading]> {
        AsyncStream { continuation in
            let task = Task {
                var tailer = ClaudeTranscriptSource(
                    projectsDirectory: projectsDirectory, quietAfter: quietAfter
                )
                var live: [String: Int32] = [:]
                var previous: [String: Reading] = [:]
                var tick = 0
                while !Task.isCancelled {
                    if tick % 10 == 0 { live = liveSessions() }
                    tick += 1
                    let readings = tailer.poll(now: Date(), liveSessions: live)
                    // Keyed on the path, which is unique; two transcripts can resolve
                    // to the same session id after a resume. `reason` is excluded so
                    // an age counter ticking up is not a change.
                    let current = Dictionary(
                        uniqueKeysWithValues: readings.map { ($0.transcriptPath, $0) }
                    )
                    if !Self.sameReadings(previous, current) {
                        previous = current
                        continuation.yield(readings)
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func sameReadings(_ a: [String: Reading], _ b: [String: Reading]) -> Bool {
        guard a.count == b.count else { return false }
        for (path, one) in a {
            guard let other = b[path],
                  one.state == other.state,
                  one.observedAt == other.observedAt,
                  one.liveness == other.liveness,
                  one.pid == other.pid,
                  one.promptClearedAt == other.promptClearedAt
            else { return false }
        }
        return true
    }

    // MARK: - Inference

    /// `(state, when the evidence was produced, why)` from a tail, oldest record
    /// first. Pure: every time-dependent decision comes from `now` and the record
    /// timestamps, so the self-check can pin the clock.
    private static func infer(
        _ records: [Record], quietAfter: TimeInterval, now: Date
    ) -> (state: AgentState, observedAt: Date, reason: String) {
        // Trap 2. `last-prompt → ai-title → mode → permission-mode` appears 508 times
        // and looks exactly like an end-of-turn flush. It is not one: the whole
        // cluster was observed *inside* the gap of a 466-second `Bash` call. These
        // types are written at unpredictable moments and mean nothing about the turn,
        // so they are removed before anything looks at "the last record".
        let evidence = records.filter { !noiseTypes.contains($0.type ?? "") }
        guard let last = evidence.last else {
            return (.unknown, now, "no state-bearing records")
        }

        // Trap 1. Most of these tail types carry no `timestamp` at all and 12 of 31
        // files end on one, so "the last record's timestamp" is nil for nearly half
        // the corpus. Scan backwards over *all* records — noise included, it is still
        // a clock reading — for the newest one that has a timestamp.
        guard let evidenceTime = records.reversed().lazy.compactMap({ $0.timestamp?.date }).first else {
            return (.unknown, now, "no timestamped record in the tail window")
        }
        let age = now.timeIntervalSince(evidenceTime)
        let quiet = age > quietAfter
        let quietNote = "quiet \(Int(age))s"

        // An API failure, distinct from a failed tool call. Reported as abstention,
        // not `.error`: see the note on `source`.
        if last.isApiErrorMessage == true || (last.type == "system" && last.subtype == "api_error") {
            return (.unknown, evidenceTime, "api error record; transient and retried, so no state is claimed")
        }

        // An unresolved `tool_use`: the assistant asked for a tool and no
        // `tool_result` with that id ever arrived.
        var pending = Set<String>()
        for record in evidence {
            switch record.type {
            case "assistant":
                for block in record.message?.content ?? [] where block.type == "tool_use" {
                    if let id = block.id { pending.insert(id) }
                }
            case "user":
                for block in record.message?.content ?? [] where block.type == "tool_result" {
                    if let id = block.toolUseID { pending.remove(id) }
                }
            default:
                break
            }
        }

        if !pending.isEmpty {
            // Nothing is written while a tool call is outstanding, verified over all
            // 76 gaps longer than 30s. So a slow tool and an open permission prompt
            // are the same bytes, and once the silence is long enough to be either,
            // the honest answer is that we do not know. This is the branch where
            // `needsInput` would have gone.
            if quiet {
                return (.unknown, evidenceTime,
                        "\(pending.count) unresolved tool call(s), \(quietNote) — a slow tool and an approval prompt are indistinguishable here")
            }
            return (.running, evidenceTime, "\(pending.count) unresolved tool call(s)")
        }

        // The only real turn boundary. `turn_duration` closes every turn in all 29
        // CLI transcripts across versions 2.1.154 → 2.1.220; `stop_hook_summary`
        // appears only with Stop hooks configured, and its counts are independent.
        if last.type == "system",
           let subtype = last.subtype,
           subtype == "turn_duration" || subtype == "stop_hook_summary" || subtype == "away_summary" {
            if quiet { return (.idle, evidenceTime, "turn ended, \(quietNote)") }
            return (.complete, evidenceTime, "turn ended (\(subtype))")
        }

        if last.type == "assistant" {
            switch last.message?.stopReason {
            case "end_turn":
                // Trap 3, and the single largest error source in the spike until it
                // was fixed (5.6% → 0.9%). `end_turn` does NOT end a turn: the CLI
                // emits one per assistant message and 115 of 372 are followed
                // immediately by another. Only `turn_duration` closes a turn, so a
                // fresh `end_turn` is precisely the ambiguity this state model exists
                // to represent.
                if quiet { return (.idle, evidenceTime, "end_turn then \(quietNote), no turn_duration") }
                return (.unknown, evidenceTime,
                        "end_turn with no turn_duration — finished, or mid-turn between assistant messages")
            case nil:
                // Streaming chunk mid-response.
                return (.running, evidenceTime, "assistant chunk, stop_reason null")
            case let reason?:
                return (.running, evidenceTime, "assistant stop_reason=\(reason)")
            }
        }

        // A `user` record with nothing pending is a prompt or a settled
        // `tool_result`; either way the assistant is about to be called again. A
        // `queue-operation` means the user typed while it was busy.
        if last.type == "user" || last.type == "queue-operation" {
            if quiet { return (.unknown, evidenceTime, "mid-turn record, \(quietNote)") }
            return (.running, evidenceTime, "mid-turn \(last.type ?? "") record")
        }

        return (.unknown, evidenceTime, "unhandled tail record \(last.type ?? "?")/\(last.subtype ?? "-")")
    }

    /// The newest moment the tail shows a permission prompt being answered, or `nil`.
    ///
    /// This is the only witness there is. Rejecting a prompt emits no hook event at
    /// all — witnessed in `spikes/needsinput` on both reject affordances: no
    /// `PermissionDenied`, no `Stop`, no `PostToolUseFailure`, and no `Notification`
    /// after 170 s idle. `PermissionRequest` turns the key amber and nothing in the
    /// hook stream can ever turn it off again, so without this the first rejection
    /// leaves a slot amber for the life of the session.
    ///
    /// Two markers, both taken from real captures, both on **`user`** records:
    ///
    ///     {"type":"tool_result","is_error":true,
    ///      "content":"The user doesn't want to proceed with this tool use. …"}
    ///     {"type":"text","text":"[Request interrupted by user for tool use]"}
    ///
    /// `is_error: true` on its own is emphatically **not** the signal — 40 routine
    /// occurrences in the tailing spike's corpus (file not read yet, string not found,
    /// exit 1, command timed out), and one of those clearing a live prompt would hide
    /// a blocked agent. Both conditions are required together: the CLI's own sentence
    /// discriminates (5 matches in the same corpus, every one a real rejection) and
    /// `is_error` keeps a quotation of that sentence in ordinary tool output from
    /// counting.
    ///
    /// Matched only inside `user` records because the assistant quotes both strings
    /// whenever it *discusses* them — this repository's own transcripts contain the
    /// prose, and an assistant paragraph must not clear a real prompt. A typed prompt
    /// cannot spoof it either: `message.content` is a plain string there, which
    /// decodes to no blocks at all.
    ///
    /// The prefix match on the interrupt marker covers the plain
    /// `[Request interrupted by user]` variant too (3 occurrences): a bare interrupt
    /// also means nothing is waiting.
    private static func promptCleared(in records: [Record]) -> Date? {
        var cleared: Date?
        var newestSoFar: Date?
        for record in records {
            if let stamped = record.timestamp?.date { newestSoFar = stamped }
            guard record.type == "user",
                  record.message?.content.contains(where: { $0.endsAPrompt }) == true
            else { continue }
            // Trap 1 again, from the safe side. Every witnessed marker carried its own
            // timestamp; if one ever does not, fall back to the newest timestamp at or
            // *before* it and never a later one. Underestimating the moment can only
            // leave amber up for another poll, while overestimating it could clear a
            // prompt that opened after the rejection.
            cleared = record.timestamp?.date ?? newestSoFar ?? cleared
        }
        return cleared
    }

    /// The CLI's fixed rejection sentence, minus the apostrophe so a typographic one
    /// cannot break the match.
    private static let rejectionMarker = "want to proceed with this tool use"
    private static let interruptMarker = "[Request interrupted by user"

    /// Types that carry no turn-state meaning. Trap 2 lives here.
    private static let noiseTypes: Set<String> = [
        "ai-title", "custom-title", "agent-name", "mode", "permission-mode",
        "last-prompt", "file-history-snapshot", "file-history-delta", "pr-link",
        "attachment",
    ]

    // MARK: - Enumeration

    /// Every main-session transcript under `directory`.
    ///
    /// Two filters, both load-bearing. `subagents/` is skipped whole: those
    /// transcripts never contain a turn-boundary record, so each one looks
    /// permanently mid-turn and every parent session would gain N phantom `running`
    /// siblings. And the match is on `*.jsonl` rather than "files in the project
    /// directory", because `memory/` directories sit alongside the transcripts.
    private static func transcripts(in directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [URL] = []
        while let url = walker.nextObject() as? URL {
            if url.hasDirectoryPath {
                if url.lastPathComponent == "subagents" { walker.skipDescendants() }
                continue
            }
            if url.pathExtension == "jsonl" { found.append(url) }
        }
        return found.sorted { $0.path < $1.path }
    }

    /// `(display id, every id this transcript might be running under)`.
    ///
    /// Two differently-spelled fields with two different meanings:
    ///
    /// - `sessionId` (camelCase) is transcript identity — equal to the filename for
    ///   a main transcript, the *parent's* id inside `subagents/`.
    /// - `session_id` (snake_case) is the id of the process that wrote the record,
    ///   which on a resumed or forked session is a **different** uuid. One observed
    ///   file carries records stamped with the id its live process actually shows in
    ///   argv, and that id is nowhere in the filename.
    ///
    /// So the process join must try every candidate. Matching on the filename alone
    /// reports a live resumed session as dead.
    private static func sessionIDs(
        _ records: [Record], path: URL
    ) -> (display: String, candidates: Set<String>) {
        let base = path.deletingPathExtension().lastPathComponent
        var candidates: Set<String> = [base]
        var display: String?
        for record in records.reversed() {
            if let writer = record.sessionIDSnake {
                candidates.insert(writer)
                if display == nil { display = writer } // newest writer wins
            }
            if let identity = record.sessionIDCamel { candidates.insert(identity) }
        }
        return (display ?? base, candidates)
    }

    // MARK: - Liveness

    /// `session id -> pid` for every running Claude CLI, from `ps`.
    ///
    /// The transcript cannot answer this: a graceful quit, a `Ctrl-C`, a crash and a
    /// session sitting at its prompt all leave an identical tail, `lsof` reports
    /// nothing even for the file being written right now (append-and-close), and file
    /// age is meaningless — two sessions were quiet ~35 minutes with live processes
    /// attached. Every running CLI does carry its id in argv, so `ps` is the join.
    /// A session launched as a bare `claude` with no `--session-id` is invisible here.
    public static func liveSessions() -> [String: Int32] {
        let ps = Process()
        ps.executableURL = URL(filePath: "/bin/ps")
        ps.arguments = ["-Ao", "pid=,command="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return [:] }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        ps.waitUntilExit()

        var live: [String: Int32] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard line.contains("claude") else { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let pid = Int32(fields.first ?? "") else { continue }
            for (index, field) in fields.enumerated() {
                if field == "--session-id", index + 1 < fields.count {
                    live[String(fields[index + 1])] = pid
                } else if field.hasPrefix("--session-id=") {
                    live[String(field.dropFirst("--session-id=".count))] = pid
                }
            }
        }
        return live
    }

    // MARK: - Reading the file

    private struct Cursor: Sendable {
        /// `nil` until the first read. Cold start takes the last `tailWindow` bytes;
        /// after that only what was appended.
        var offset: UInt64?
        var records: [Record] = []
    }

    /// `(new records, offset to resume from)`, or nil if the file could not be read.
    /// A partial trailing line is left for the next poll rather than parsed half-way.
    private static func readTail(_ url: URL, from offset: UInt64?) -> ([Record], UInt64)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0

        var start: UInt64
        var dropLeadingPartial = false
        if let offset {
            // Truncated or replaced: start over.
            start = offset > size ? 0 : offset
        } else if size > tailWindow {
            start = size - tailWindow
            dropLeadingPartial = true
        } else {
            start = 0
        }
        guard start < size else { return ([], start) }
        try? handle.seek(toOffset: start)
        guard var buffer = try? handle.readToEnd(), !buffer.isEmpty else { return ([], start) }

        if dropLeadingPartial, let newline = buffer.firstIndex(of: 0x0A) {
            start += UInt64(buffer.distance(from: buffer.startIndex, to: newline)) + 1
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        guard let lastNewline = buffer.lastIndex(of: 0x0A) else { return ([], start) }
        let complete = Data(buffer[..<buffer.index(after: lastNewline)])

        let decoder = JSONDecoder()
        var records: [Record] = []
        for line in complete.split(separator: 0x0A) where !line.isEmpty {
            if let record = try? decoder.decode(Record.self, from: Data(line)) {
                records.append(record)
            }
        }
        return (records, start + UInt64(complete.count))
    }

    // MARK: - Record shape

    /// Only the fields the rules read. Decoding is deliberately forgiving — an
    /// unrecognised or malformed record must cost us that record's information, never
    /// the whole tail.
    private struct Record: Decodable, Sendable {
        let type: String?
        let subtype: String?
        let timestamp: Timestamp?
        let isApiErrorMessage: Bool?
        let sessionIDSnake: String?
        let sessionIDCamel: String?
        let message: Message?

        enum CodingKeys: String, CodingKey {
            case type, subtype, timestamp, isApiErrorMessage, message
            case sessionIDSnake = "session_id"
            case sessionIDCamel = "sessionId"
        }
    }

    private struct Message: Decodable, Sendable {
        let stopReason: String?
        let content: [Block]

        enum CodingKeys: String, CodingKey {
            case stopReason = "stop_reason"
            case content
        }

        /// Never throws. `content` is an array of blocks on assistant records and a
        /// plain string on a typed prompt, and `message` itself is not always an
        /// object, so every shape that is not the one we want degrades to "no blocks"
        /// instead of discarding the record.
        init(from decoder: any Decoder) throws {
            let container = try? decoder.container(keyedBy: CodingKeys.self)
            stopReason = try? container?.decodeIfPresent(String.self, forKey: .stopReason) ?? nil
            content = (try? container?.decode([Block].self, forKey: .content) ?? []) ?? []
        }
    }

    private struct Block: Decodable, Sendable {
        let type: String?
        let id: String?
        let toolUseID: String?
        let text: String?
        let isError: Bool?
        /// `tool_result.content` is a plain string in every captured rejection, but the
        /// schema also allows an array of blocks. Decoded by hand for that reason: a
        /// throw here would fail the whole `[Block]` decode and lose the `tool_use`
        /// pairing the `running`/`idle` rules depend on, so an unexpected shape costs
        /// this one block its content and nothing else.
        let content: String?

        enum CodingKeys: String, CodingKey {
            case type, id, text, content
            case toolUseID = "tool_use_id"
            case isError = "is_error"
        }

        init(from decoder: any Decoder) throws {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            type = try? c?.decodeIfPresent(String.self, forKey: .type) ?? nil
            id = try? c?.decodeIfPresent(String.self, forKey: .id) ?? nil
            toolUseID = try? c?.decodeIfPresent(String.self, forKey: .toolUseID) ?? nil
            text = try? c?.decodeIfPresent(String.self, forKey: .text) ?? nil
            isError = try? c?.decodeIfPresent(Bool.self, forKey: .isError) ?? nil
            if let string = try? c?.decodeIfPresent(String.self, forKey: .content) ?? nil {
                content = string
            } else if let nested = try? c?.decode([Block].self, forKey: .content) {
                content = nested.compactMap(\.text).joined(separator: "\n")
            } else {
                content = nil
            }
        }

        /// Whether this block is one of the two markers that a permission prompt has
        /// been answered. See `promptCleared(in:)` for why both halves of the
        /// `tool_result` condition are required.
        var endsAPrompt: Bool {
            switch type {
            case "tool_result":
                isError == true && content?.contains(rejectionMarker) == true
            case "text":
                text?.hasPrefix(interruptMarker) == true
            default:
                false
            }
        }
    }

    /// ISO8601 with or without fractional seconds, parsed once at decode rather than
    /// on every poll.
    private struct Timestamp: Decodable, Sendable {
        let date: Date?

        init(from decoder: any Decoder) throws {
            let raw = try? decoder.singleValueContainer().decode(String.self)
            date = raw.flatMap(ClaudeTranscriptSource.parseTimestamp)
        }
    }

    static func parseTimestamp(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}

// MARK: - Self check

public extension ClaudeTranscriptSource {
    /// Human-readable failures, empty when healthy. Wire into `SelfCheck` with:
    ///
    ///     failures += ClaudeTranscriptSource.selfCheckFailures().map { "tail: \($0)" }
    ///
    /// Runs against fixtures written into a fresh temporary directory and a pinned
    /// clock. It never reads `~/.claude`: live transcripts change under the check,
    /// which would make it flake, and the states worth asserting (a doubled
    /// `end_turn`, a timestampless tail) may not be present on any given machine at
    /// any given moment.
    static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        check(
            "quietAfter must stay under the source staleness threshold or idle can never reach a key",
            ClaudeTranscriptSource().quietAfter < source.stalenessThreshold
        )

        let root = FileManager.default.temporaryDirectory
            .appending(path: "vcm-transcript-selfcheck-\(UUID().uuidString)")
        let project = root.appending(path: "-Users-fixture-proj")
        defer { try? FileManager.default.removeItem(at: root) }

        // Pinned clock: fresh records are 10s old, stale ones 610s, either side of
        // the 60s default.
        guard let now = parseTimestamp("2026-07-26T12:00:10.000Z") else {
            return failures + ["fixture clock did not parse"]
        }
        let fresh = "2026-07-26T12:00:00.000Z"
        let earlier = "2026-07-26T11:59:55.000Z"
        let stale = "2026-07-26T11:50:00.000Z"
        guard let freshDate = parseTimestamp(fresh) else {
            return failures + ["fixture timestamp did not parse"]
        }

        func line(_ fields: String...) -> String { "{" + fields.joined(separator: ",") + "}" }
        func assistant(_ stopReason: String, _ blocks: String, at time: String) -> String {
            line("\"type\":\"assistant\"", "\"timestamp\":\"\(time)\"",
                 "\"message\":{\"stop_reason\":\"\(stopReason)\",\"content\":[\(blocks)]}")
        }
        func toolUse(_ id: String, _ name: String) -> String {
            "{\"type\":\"tool_use\",\"id\":\"\(id)\",\"name\":\"\(name)\"}"
        }
        func user(_ blocks: String, at time: String) -> String {
            line("\"type\":\"user\"", "\"timestamp\":\"\(time)\"",
                 "\"message\":{\"content\":[\(blocks)]}")
        }
        func toolResult(_ id: String, error: Bool, _ content: String) -> String {
            "{\"type\":\"tool_result\",\"tool_use_id\":\"\(id)\",\"is_error\":\(error)," +
            "\"content\":\"\(content)\"}"
        }
        func textBlock(_ text: String) -> String {
            "{\"type\":\"text\",\"text\":\"\(text)\"}"
        }
        func turnEnd(at time: String) -> String {
            line("\"type\":\"system\"", "\"subtype\":\"turn_duration\"", "\"timestamp\":\"\(time)\"")
        }
        // Verbatim from spikes/needsinput/capture-no and capture-deny — both reject
        // affordances produced this exact pair.
        let rejectionText =
            "The user doesn't want to proceed with this tool use. The tool use was rejected …"
        let interruptText = "[Request interrupted by user for tool use]"
        // The cluster from trap 2, in the order it actually appears, none of it
        // timestamped.
        let metadataCluster = [
            line("\"type\":\"last-prompt\""), line("\"type\":\"ai-title\""),
            line("\"type\":\"mode\""), line("\"type\":\"permission-mode\""),
        ]

        // 1. turn boundary, then the metadata cluster with no timestamps after it.
        let boundary = ["turn-boundary.jsonl": [
            assistant("end_turn", "{\"type\":\"text\",\"text\":\"x\"}", at: earlier),
            line("\"type\":\"system\"", "\"subtype\":\"turn_duration\"", "\"timestamp\":\"\(fresh)\""),
        ] + metadataCluster]

        // 2. the same cluster written *inside* an outstanding tool call.
        let midTool = ["cluster-mid-tool.jsonl": [
            assistant("tool_use", toolUse("t1", "Bash"), at: fresh),
        ] + metadataCluster]

        // 3. two end_turns inside one turn.
        let doubled = ["doubled-end-turn.jsonl": [
            assistant("end_turn", "{\"type\":\"text\",\"text\":\"a\"}", at: fresh),
            assistant("end_turn", "{\"type\":\"text\",\"text\":\"b\"}", at: fresh),
        ]]

        // 4. a resumed session: the records' session_id is not the filename.
        let resumedFile = "aaaaaaaa-0000-0000-0000-00000000004a.jsonl"
        let resumedWriter = "bbbbbbbb-0000-0000-0000-00000000004b"
        let resumed = [resumedFile: [
            line("\"type\":\"system\"", "\"subtype\":\"turn_duration\"", "\"timestamp\":\"\(stale)\"",
                 "\"sessionId\":\"aaaaaaaa-0000-0000-0000-00000000004a\"",
                 "\"session_id\":\"\(resumedWriter)\""),
        ]]

        // 5 + 6. AskUserQuestion outstanding, long and short. Neither may be amber.
        let asking = [
            "asking-stale.jsonl": [assistant("tool_use", toolUse("t9", "AskUserQuestion"), at: stale)],
            "asking-fresh.jsonl": [assistant("tool_use", toolUse("t8", "AskUserQuestion"), at: fresh)],
        ]

        // 7. A rejected permission prompt, in the record order the spike captured.
        let rejected = ["rejected.jsonl": [
            assistant("tool_use", toolUse("r1", "Bash"), at: earlier),
            user(toolResult("r1", error: true, rejectionText), at: fresh),
            user(textBlock(interruptText), at: fresh),
            turnEnd(at: fresh),
        ]]

        // 8. A routine failed tool call. `is_error: true` and NOT a rejection: 40 of
        //    these in the corpus, and any one of them clearing a live prompt would hide
        //    a blocked agent.
        let toolError = ["tool-error.jsonl": [
            assistant("tool_use", toolUse("e1", "Bash"), at: earlier),
            user(toolResult("e1", error: true, "Exit code 1: command not found"), at: fresh),
            turnEnd(at: fresh),
        ]]

        // 8b. A *successful* tool call whose output happens to quote the sentence —
        //     `grep` over this repository's own findings does exactly that. The
        //     is_error half of the condition is what stops it counting.
        let quotingOutput = ["quoting-output.jsonl": [
            assistant("tool_use", toolUse("q1", "Bash"), at: earlier),
            user(toolResult("q1", error: false, rejectionText), at: fresh),
            turnEnd(at: fresh),
        ]]

        // 9. A bare interrupt, no tool_result. Also means nothing is waiting.
        let interrupted = ["interrupted.jsonl": [
            assistant("end_turn", textBlock("x"), at: earlier),
            user(textBlock("[Request interrupted by user]"), at: fresh),
            turnEnd(at: fresh),
        ]]

        // 10. The assistant *talking about* a rejection. This repository's own
        //     transcripts contain both markers as prose, so an assistant paragraph must
        //     never clear a real prompt.
        let quoted = ["quoted.jsonl": [
            assistant("end_turn", textBlock(interruptText) + "," + textBlock(rejectionText), at: fresh),
        ]]

        var fixtures: [String: [String]] = [:]
        for group in [boundary, midTool, doubled, resumed, asking, rejected, toolError,
                      quotingOutput, interrupted, quoted] {
            fixtures.merge(group) { a, _ in a }
        }

        do {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            for (name, lines) in fixtures {
                try (lines.joined(separator: "\n") + "\n")
                    .write(to: project.appending(path: name), atomically: true, encoding: .utf8)
            }
            // Must be excluded: a subagent transcript never contains a turn boundary,
            // so it looks permanently mid-turn.
            let subagents = project.appending(path: "turn-boundary/subagents")
            try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
            try (assistant("tool_use", toolUse("s1", "Bash"), at: fresh) + "\n")
                .write(to: subagents.appending(path: "agent-fixture.jsonl"), atomically: true, encoding: .utf8)
            // Must be ignored: `memory/` sits alongside the transcripts.
            let memory = project.appending(path: "memory")
            try FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
            try "not a transcript\n".write(
                to: memory.appending(path: "MEMORY.md"), atomically: true, encoding: .utf8
            )
        } catch {
            return failures + ["could not write fixtures: \(error)"]
        }

        var tailer = ClaudeTranscriptSource(projectsDirectory: root)
        // Every fixture id is live except the resumed one, which is live only under
        // the id its records carry — not under its filename.
        var live: [String: Int32] = [resumedWriter: 4242]
        for name in fixtures.keys where name != resumedFile {
            live[String(name.dropLast(6))] = 1
        }
        let withProcesses = tailer.poll(now: now, liveSessions: live)
        // Same cursors, no growth: re-inferred from the cached records, and this time
        // nothing is alive.
        let withoutProcesses = tailer.poll(now: now, liveSessions: [:])

        func state(_ readings: [Reading], _ file: String) -> AgentState? {
            readings.first { URL(filePath: $0.transcriptPath).lastPathComponent == file }?.state
        }

        check("expected one reading per top-level transcript", withProcesses.count == fixtures.count)
        check(
            "subagent transcripts must be excluded",
            withProcesses.allSatisfy { !$0.transcriptPath.contains("/subagents/") }
        )
        check(
            "only *.jsonl is a transcript",
            withProcesses.allSatisfy { $0.transcriptPath.hasSuffix(".jsonl") }
        )

        // Trap 1: the tail ends on four untimestamped records, so the reading must
        // date itself from the turn_duration before them.
        let boundaryReading = withProcesses.first {
            URL(filePath: $0.transcriptPath).lastPathComponent == "turn-boundary.jsonl"
        }
        check("turn_duration reads as complete", boundaryReading?.state == .complete)
        check(
            "a tail ending on untimestamped records still dates itself from earlier evidence",
            boundaryReading?.observedAt == freshDate
        )
        check("a matched process is alive", boundaryReading?.liveness == .alive)

        // Trap 2.
        check(
            "the metadata cluster inside a tool call is not a turn boundary",
            state(withProcesses, "cluster-mid-tool.jsonl") == .running
        )
        // Trap 3.
        check(
            "a doubled end_turn does not read as complete",
            state(withProcesses, "doubled-end-turn.jsonl") == .unknown
        )

        // The id join, and the pid gate.
        let resumedReading = withProcesses.first {
            URL(filePath: $0.transcriptPath).lastPathComponent == resumedFile
        }
        check("a quiet turn boundary with a live process is idle", resumedReading?.state == .idle)
        check(
            "the process join uses the record's session_id, not the filename",
            resumedReading?.pid == 4242 && resumedReading?.sessionID == resumedWriter
        )
        check(
            "with no matching process, idle resolves to unknown",
            state(withoutProcesses, resumedFile) == .unknown
        )
        check(
            "an unmatched session is never asserted dead",
            withoutProcesses.allSatisfy { $0.liveness == .unknown && $0.pid == nil }
        )

        // The whole point of the source: it cannot see a pending prompt, so it must
        // never claim to. AskUserQuestion included — that exception is dropped.
        check(
            "a long unresolved tool call abstains",
            state(withProcesses, "asking-stale.jsonl") == .unknown
        )
        check(
            "a fresh unresolved tool call is running, not waiting",
            state(withProcesses, "asking-fresh.jsonl") == .running
        )
        // The reject path. A rejection is the one thing about a permission prompt this
        // source can witness, and it must express it WITHOUT reporting needsInput.
        func reading(_ file: String) -> Reading? {
            withProcesses.first { URL(filePath: $0.transcriptPath).lastPathComponent == file }
        }
        check("a rejection is dated from its own record", reading("rejected.jsonl")?.promptClearedAt == freshDate)
        check("a bare interrupt also ends a prompt", reading("interrupted.jsonl")?.promptClearedAt == freshDate)
        check(
            "a tool_result with is_error true is not a rejection",
            reading("tool-error.jsonl")?.promptClearedAt == nil
        )
        check(
            "a failed tool call must not read as error",
            state(withProcesses, "tool-error.jsonl") == .complete
        )
        check(
            "the assistant quoting the markers must not end a prompt",
            reading("quoted.jsonl")?.promptClearedAt == nil
        )
        check(
            "successful tool output quoting the sentence must not end a prompt",
            reading("quoting-output.jsonl")?.promptClearedAt == nil
        )
        check(
            "nothing else in the fixtures ends a prompt",
            withProcesses.filter { $0.promptClearedAt != nil }.count == 2
        )
        check(
            "the tail still resolves the rejected tool call, so the turn reads as ended",
            state(withProcesses, "rejected.jsonl") == .complete
        )

        // Through the engine, which is where it has to work: hooks turn the key amber
        // and nothing in the hook stream ever turns it off again.
        if let rejection = reading("rejected.jsonl"), let clearedAt = rejection.promptClearedAt {
            let hooks = StateSource.claudeHooks
            let amberAt = clearedAt.addingTimeInterval(-1) // PermissionRequest, then the reject
            var engine = StateEngine(sources: [hooks, source])
            engine.record(.needsInput, for: rejection.sessionID, from: hooks.id, observedAt: amberAt)
            engine.record(rejection.state, for: rejection.sessionID, from: source.id, observedAt: rejection.observedAt)
            check(
                "PermissionRequest should still win before the rejection is seen",
                engine.resolve(rejection.sessionID, at: clearedAt).state == .needsInput
            )
            check(
                "clearing needsInput must be accepted from a source that cannot report it",
                engine.clearNeedsInput(for: rejection.sessionID, from: source.id, observedAt: clearedAt) == .accepted
            )
            let after = engine.resolve(rejection.sessionID, at: clearedAt)
            check("a witnessed rejection must take the key off amber", after.state != .needsInput)
            check("and must leave the state the transcript actually witnessed", after.state == rejection.state)
            check("clearing must not be logged as a rejected ingest", engine.rejections.isEmpty)

            // The trap that makes the timestamp load-bearing: the marker stays in the
            // tail window, so this runs again on every poll. A prompt opened *after* it
            // must survive.
            let nextPrompt = clearedAt.addingTimeInterval(5)
            engine.record(.needsInput, for: rejection.sessionID, from: hooks.id, observedAt: nextPrompt)
            engine.clearNeedsInput(for: rejection.sessionID, from: source.id, observedAt: clearedAt)
            check(
                "a stale rejection marker must not clear the next prompt",
                engine.resolve(rejection.sessionID, at: nextPrompt).state == .needsInput
            )
        } else {
            failures.append("the rejection fixture produced no reading to test the engine with")
        }

        // The other half: a failed tool call offers nothing to clear, so amber stands.
        if let routine = reading("tool-error.jsonl") {
            let hooks = StateSource.claudeHooks
            var engine = StateEngine(sources: [hooks, source])
            let amberAt = routine.observedAt.addingTimeInterval(-1)
            engine.record(.needsInput, for: routine.sessionID, from: hooks.id, observedAt: amberAt)
            engine.record(routine.state, for: routine.sessionID, from: source.id, observedAt: routine.observedAt)
            if let cleared = routine.promptClearedAt {
                engine.clearNeedsInput(for: routine.sessionID, from: source.id, observedAt: cleared)
            }
            check(
                "a routine tool failure must not take a key off amber",
                engine.resolve(routine.sessionID, at: routine.observedAt).state == .needsInput
            )
        }

        for readings in [withProcesses, withoutProcesses] {
            check(
                "this source must never report needsInput",
                readings.allSatisfy { $0.state != .needsInput }
            )
            check(
                "every reading must be inside the declared vocabulary",
                readings.allSatisfy { source.reportableStates.contains($0.state) }
            )
            check(
                "no reading may be timestamped in the future",
                readings.allSatisfy { $0.observedAt <= now }
            )
        }

        return failures
    }
}
