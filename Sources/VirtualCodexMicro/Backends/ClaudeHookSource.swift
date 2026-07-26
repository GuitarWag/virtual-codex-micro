import Foundation

// MARK: - JSON

/// A `Sendable` JSON tree. Exists for two jobs that both need one:
///
/// 1. `PermissionRequest` carries `tool_input` and `permission_suggestions`, which
///    are arbitrary JSON the accept/reject keys have to act on. `[String: Any]` is
///    not `Sendable`, so it cannot cross an `AsyncStream` under strict concurrency.
/// 2. The installer must re-serialize `~/.claude/settings.json` *without* escaping
///    slashes, or every path in the user's config comes back as `\/Users\/…`.
///    `JSONSerialization` has no such option; `JSONEncoder` does, but only for
///    `Encodable` values.
///
/// `int` is kept separate from `double` so a `"timeout": 10` in the user's settings
/// does not come back as `10.0`.
public enum JSONValue: Sendable, Equatable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unrepresentable JSON")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        switch self {
        case .int(let v): v
        case .double(let v): Int(v)
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Non-throwing on purpose: a malformed payload must be dropped, never crash
    /// the receiver and never half-parse into a wrong state.
    public static func parse(_ data: Data) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Deterministic bytes. `sortedKeys` is what makes an install/uninstall round
    /// trip byte-for-byte reversible; `withoutEscapingSlashes` is what keeps the
    /// consent diff readable.
    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

// MARK: - Events

/// What a received hook event means for a slot. `ignored` carries its reason
/// because "we saw it and deliberately did nothing" and "we did not understand it"
/// must be distinguishable in the activity log.
///
/// The state is only reachable through this enum, so a consumer cannot read a
/// colour off an event without first passing the subagent and payload filters.
public enum HookOutcome: Sendable, Equatable {
    case state(AgentState)
    /// `SessionStart`. `source` is `startup`, `resume`, `clear`, `compact` or `fork`.
    case openSlot(source: String?)
    /// `SessionEnd`. `reason` is one of the CLI's own: `clear`, `resume`, `logout`,
    /// `prompt_input_exit`, `other`, `bypass_permissions_disabled`.
    case closeSlot(reason: String?)
    case ignored(String)

    public var state: AgentState? {
        if case .state(let s) = self { return s }
        return nil
    }
}

/// One decoded hook payload. Field names follow the CLI's own envelope schema
/// (verified against 2.1.220's zod definitions, not the docs).
public struct HookEvent: Sendable, Equatable {
    public let name: String
    public let sessionID: String
    public let transcriptPath: String?
    public let cwd: String?
    public let promptID: String?
    public let permissionMode: String?
    public let effortLevel: String?
    /// Present **only** inside a subagent. The single mark that distinguishes a
    /// `SubagentStop` from the main `Stop` it trails by ~3.8s (gap G4), so any
    /// event carrying it is dropped before the mapping table is consulted.
    ///
    /// Not `agentType`: that is also set on the *main* thread of an `--agent`
    /// session, so filtering on it would blind us to whole sessions.
    public let agentID: String?
    public let agentType: String?
    /// `SessionStart` only.
    public let source: String?
    /// `SessionEnd` only.
    public let reason: String?
    /// `Notification` only. Eleven values share this channel, including login
    /// toasts, so only `idle_prompt` is acted on.
    public let notificationType: String?
    public let toolName: String?
    /// Preserved verbatim: the accept key needs the command it is approving.
    public let toolInput: JSONValue?
    /// Preserved verbatim: the accept key applies one of these to grant the rule.
    public let permissionSuggestions: JSONValue?
    /// From the forwarder's `CLAUDE_PID`, not from the payload — the JSON has no
    /// pid and no tty. This is the head of the
    /// `session_id → pid → tty → window` chain that focus and liveness both need,
    /// and it is why every entry is a `command` hook.
    public let claudePID: Int32?
    public let termProgram: String?
    public let entrypoint: String?
    /// The moment the evidence was produced — the spool file's mtime, i.e. when the
    /// hook fired, not when we got round to reading it. `StateEngine` measures
    /// staleness from this, so the distinction is load-bearing.
    public let observedAt: Date
    /// Everything, including fields we do not model yet. 31 event names exist today
    /// and the enum grows between releases.
    public let raw: JSONValue

    public var outcome: HookOutcome { ClaudeHookSource.outcome(for: self) }

    /// Parses one spool file. Returns `nil` — never throws, never traps — for
    /// anything it cannot make sense of: truncated writes, a payload that is not an
    /// object, a missing `session_id` (unattributable, so useless), a missing
    /// `hook_event_name` (unmappable).
    ///
    /// The file may begin with one tab-separated metadata line written by the
    /// forwarder, carrying the environment the JSON payload does not have. A file
    /// starting with `{` is a bare payload and still parses.
    public static func parse(_ data: Data, observedAt: Date) -> HookEvent? {
        var payload = data
        var pid: Int32?
        var term: String?
        var entrypoint: String?

        if data.first != UInt8(ascii: "{"), let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            let header = String(decoding: data[data.startIndex..<newline], as: UTF8.self)
            payload = data[data.index(after: newline)...]
            for field in header.split(separator: "\t") {
                guard let eq = field.firstIndex(of: "=") else { continue }
                let value = String(field[field.index(after: eq)...])
                guard !value.isEmpty else { continue }
                switch field[field.startIndex..<eq] {
                case "pid": pid = Int32(value)
                case "term": term = value
                case "entry": entrypoint = value
                default: break
                }
            }
        }

        guard let root = JSONValue.parse(payload),
              let name = root["hook_event_name"]?.stringValue,
              let sessionID = root["session_id"]?.stringValue,
              !name.isEmpty, !sessionID.isEmpty
        else { return nil }

        return HookEvent(
            name: name,
            sessionID: sessionID,
            transcriptPath: root["transcript_path"]?.stringValue,
            cwd: root["cwd"]?.stringValue,
            promptID: root["prompt_id"]?.stringValue,
            permissionMode: root["permission_mode"]?.stringValue,
            effortLevel: root["effort"]?["level"]?.stringValue,
            agentID: root["agent_id"]?.stringValue,
            agentType: root["agent_type"]?.stringValue,
            source: root["source"]?.stringValue,
            reason: root["reason"]?.stringValue,
            notificationType: root["notification_type"]?.stringValue,
            toolName: root["tool_name"]?.stringValue,
            toolInput: root["tool_input"],
            permissionSuggestions: root["permission_suggestions"],
            claudePID: pid,
            termProgram: term,
            entrypoint: entrypoint,
            observedAt: observedAt,
            raw: root
        )
    }
}

// MARK: - Source

/// Receives Claude Code hook events and turns them into readings for
/// `StateSource.claudeHooks`. The only source that can ever turn a key amber:
/// a pending permission prompt writes nothing to the transcript, so if this is not
/// installed, `needsInput` is not merely late — it is invisible.
///
/// **Delivery is a spool directory, not a socket.** Each installed hook entry is a
/// `command` hook with `async: true` that writes one file and exits. Nothing in the
/// user's session ever waits on this process, which is the requirement gap G5
/// names: hooks block the transition synchronously, and a wedged listener degrading
/// somebody's agent is a worse failure than a stale colour on a key. A spool also
/// means events survive the panel not running yet.
///
/// This type maps events to states and hands them out. It does not talk to
/// `StateEngine` — the registry owns that, and records with `sourceID` and the
/// event's `observedAt`.
public final class ClaudeHookSource: Sendable {
    /// Matches `StateSource.claudeHooks.id`. Recording under any other id is
    /// rejected by the engine as an unregistered source.
    public static let sourceID = StateSource.claudeHooks.id

    public let spoolDirectory: URL
    private let spool: Spool

    public init(
        spoolDirectory: URL = ClaudeHookSource.defaultSpoolDirectory,
        pollInterval: Duration = .milliseconds(200)
    ) {
        self.spoolDirectory = spoolDirectory
        spool = Spool(directory: spoolDirectory, pollInterval: pollInterval)
    }

    public static let defaultSpoolDirectory = ClaudeHookInstaller.supportDirectory
        .appendingPathComponent("hook-spool", isDirectory: true)

    /// Every event, in the order the hooks fired, including the ignored ones — the
    /// activity strip (task 027) exists to show what we received and chose not to
    /// act on. Watching starts on first subscribe and stops when the last
    /// subscriber goes away.
    public func events() -> AsyncStream<HookEvent> {
        let spool = self.spool
        return AsyncStream { continuation in
            let token = UUID()
            continuation.onTermination = { _ in
                Task { await spool.unsubscribe(token) }
            }
            Task { await spool.subscribe(token, continuation) }
        }
    }

    public func stop() async {
        await spool.stopWatching()
    }

    /// One drain, no watcher. For the drift guard's reconcile-on-wake (task 028)
    /// and for the self-check, which must not depend on a timer.
    @discardableResult
    public func drainNow() -> [HookEvent] {
        Self.drain(directory: spoolDirectory)
    }

    // MARK: - Mapping

    /// What an event name means. `ignore` carries its reason so the table doubles
    /// as the documentation of why 20 of the 31 events are not state signals.
    public enum Disposition: Sendable, Equatable {
        case state(AgentState)
        case openSlot
        case closeSlot
        /// `Notification`, which is only a signal for one of its eleven types.
        case idleNotification
        case ignore(String)
    }

    /// The CLI's closed `hook_event_name` enum, read out of 2.1.220's own schema.
    /// **31 names**, not the 30 the findings' prose says — the list in the findings
    /// is right, the count is off by one, and the binary agrees with the list.
    ///
    /// Kept as data so `selfCheckFailures()` can prove `dispositions` covers every
    /// one of them. There is no `default` branch anywhere in the mapping: an
    /// unlisted name is `ignored`, which is also what a newer CLI's new event gets.
    public static let knownEventNames: Set<String> = [
        "PreToolUse", "PostToolUse", "PostToolUseFailure", "PostToolBatch",
        "Notification", "UserPromptSubmit", "UserPromptExpansion", "SessionStart",
        "SessionEnd", "Stop", "StopFailure", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact", "PermissionRequest", "PermissionDenied",
        "Setup", "TeammateIdle", "TaskCreated", "TaskCompleted", "Elicitation",
        "ElicitationResult", "ConfigChange", "WorktreeCreate", "WorktreeRemove",
        "InstructionsLoaded", "CwdChanged", "FileChanged", "DirectoryAdded",
        "MessageDisplay",
    ]

    /// The M0 spike's table, one entry per known event name.
    ///
    /// Latencies measured externally (the tool printing its own epoch-millis, a
    /// timestamped PTY write): `PermissionRequest` 1ms, `PreToolUse` 18ms, `Stop`
    /// 25ms, `PostToolUse` 31ms. All of it thirty times inside the 1s criterion.
    public static let dispositions: [String: Disposition] = [
        // running — directly witnessed, the whole turn is covered.
        "UserPromptSubmit": .state(.running),
        "PreToolUse": .state(.running),
        "PostToolUse": .state(.running),
        "PostToolBatch": .state(.running),

        // complete — only with agent_id absent, which the global filter guarantees.
        "Stop": .state(.complete),

        // needsInput — 1ms, unconditional, and the payload the accept/reject keys
        // act on. NOT Notification: that is a fixed 6.00s debounce (measured 6004 /
        // 6005 / 6002 ms) that is suppressed exactly while the user is present.
        "PermissionRequest": .state(.needsInput),

        // idle — no event marks the instant a session goes idle. This is the one
        // Notification type worth having: a genuine "waiting on a human for a
        // minute" (messageIdleNotifThresholdMs, default 60000) that nothing else
        // reports.
        "Notification": .idleNotification,

        // error — UNVERIFIED. Both were registered across all 12 spike sessions and
        // NEVER FIRED, because nothing failed. The names come from the binary's
        // enum, so they exist; the payload shape and the conditions that trigger
        // them are guesses. Reproducing a real turn failure is open follow-up work.
        // Until then the red key is the least trustworthy thing on the panel.
        "StopFailure": .state(.error),
        "PostToolUseFailure": .state(.error),

        // Slot lifecycle.
        "SessionStart": .openSlot,
        "SessionEnd": .closeSlot,

        // Deliberately ignored. Each of these either says nothing about turn state
        // or says something we cannot trust.
        "SubagentStart": .ignore("subagent lifecycle; a subagent must never move the parent's slot (G4)"),
        "SubagentStop": .ignore("subagent lifecycle; landed 3.8s after the main Stop in the spike (G4)"),
        "PermissionDenied": .ignore("never fired in 12 sessions (G6); no proven signal, and guessing a state on a rejection is exactly the drift the panel must not have"),
        "Elicitation": .ignore("a real needsInput candidate, but never fired in the spike — unmeasured, so unmapped"),
        "ElicitationResult": .ignore("pairs with Elicitation, which is unmapped"),
        "UserPromptExpansion": .ignore("fires alongside UserPromptSubmit, which already says running"),
        "PreCompact": .ignore("context maintenance; the turn's state is unchanged"),
        "PostCompact": .ignore("context maintenance; the turn's state is unchanged"),
        "Setup": .ignore("keyed to init/maintenance, never fired in a session"),
        "TeammateIdle": .ignore("another teammate's session, not ours"),
        "TaskCreated": .ignore("background task bookkeeping, not turn state"),
        "TaskCompleted": .ignore("background task bookkeeping, not turn state"),
        "ConfigChange": .ignore("settings changed, which is not session state"),
        "WorktreeCreate": .ignore("vcs bookkeeping"),
        "WorktreeRemove": .ignore("vcs bookkeeping"),
        "InstructionsLoaded": .ignore("fired 3x at startup in the spike; carries no turn state"),
        "CwdChanged": .ignore("location, not state; the session detail popover's business"),
        "FileChanged": .ignore("workspace edit, not turn state"),
        "DirectoryAdded": .ignore("workspace edit, not turn state"),
        "MessageDisplay": .ignore("a render event; would fire constantly and mean nothing"),
    ]

    /// Pure function, no I/O, so the whole table is testable without a CLI.
    public static func outcome(for event: HookEvent) -> HookOutcome {
        // First, unconditionally, before the table: a subagent event must not move
        // the slot. Filtering on agent_id and not agent_type is deliberate —
        // agent_type is also set on the main thread of an `--agent` session.
        if let agentID = event.agentID, !agentID.isEmpty {
            return .ignored("subagent event (agent_id=\(agentID))")
        }
        guard let disposition = dispositions[event.name] else {
            return .ignored("unrecognised hook event '\(event.name)'")
        }
        switch disposition {
        case .state(let state):
            return .state(state)
        case .openSlot:
            return .openSlot(source: event.source)
        case .closeSlot:
            return .closeSlot(reason: event.reason)
        case .idleNotification:
            guard event.notificationType == "idle_prompt" else {
                return .ignored("notification_type '\(event.notificationType ?? "none")' is not idle_prompt")
            }
            return .state(.idle)
        case .ignore(let why):
            return .ignored(why)
        }
    }

    // MARK: - Spool

    /// Reads and *removes* every complete payload in the spool, oldest first.
    ///
    /// Ordered by mtime, not filename: two events 1ms apart must not be replayed
    /// out of order, and a one-second-resolution name would let `PreToolUse`
    /// overwrite the `PermissionRequest` that followed it. The kernel already
    /// timestamps the write, so there is nothing to invent.
    ///
    /// Each file is deleted before it is parsed. A payload we cannot read must not
    /// be retried forever, and a crash mid-drain must not replay on restart.
    static func drain(directory: URL) -> [HookEvent] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // Only `.json`: the forwarder writes to a temp name and renames, so an
        // in-flight payload is never visible under an extension we look at.
        let files = entries
            .filter { $0.pathExtension == "json" }
            .map { url -> (url: URL, mtime: Date) in
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date.distantPast
                return (url, mtime)
            }
            .sorted { ($0.mtime, $0.url.lastPathComponent) < ($1.mtime, $1.url.lastPathComponent) }

        var events: [HookEvent] = []
        for file in files {
            let data = try? Data(contentsOf: file.url)
            try? fm.removeItem(at: file.url)
            if let data, let event = HookEvent.parse(data, observedAt: file.mtime) {
                events.append(event)
            }
        }
        return events
    }

    /// Poll rather than a vnode `DispatchSource`: no file descriptor to keep alive,
    /// nothing to re-arm when the directory is recreated, and the tailer (task 022)
    /// already runs a 200ms tick, so this adds no new class of wakeup.
    // ponytail: 200ms poll caps end-to-end latency at ~230ms against the hook's own
    // 6-31ms. Well inside the 1s criterion; swap in a directory vnode source if a
    // key ever needs to light faster than a human can notice.
    private actor Spool {
        private let directory: URL
        private let pollInterval: Duration
        private var subscribers: [UUID: AsyncStream<HookEvent>.Continuation] = [:]
        private var watcher: Task<Void, Never>?

        init(directory: URL, pollInterval: Duration) {
            self.directory = directory
            self.pollInterval = pollInterval
        }

        func subscribe(_ token: UUID, _ continuation: AsyncStream<HookEvent>.Continuation) {
            subscribers[token] = continuation
            startWatching()
        }

        func unsubscribe(_ token: UUID) {
            subscribers[token] = nil
            if subscribers.isEmpty { stopWatching() }
        }

        func stopWatching() {
            watcher?.cancel()
            watcher = nil
        }

        private func startWatching() {
            guard watcher == nil else { return }
            let interval = pollInterval
            watcher = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.pump()
                    do { try await Task.sleep(for: interval) } catch { return }
                }
            }
        }

        private func pump() {
            let directory = self.directory
            for event in ClaudeHookSource.drain(directory: directory) {
                for continuation in subscribers.values { continuation.yield(event) }
            }
        }
    }
}

// MARK: - Self check

public extension ClaudeHookSource {
    /// Human-readable failures, empty when healthy. Wire into `SelfCheck` with:
    ///
    ///     failures += ClaudeHookSource.selfCheckFailures().map { "hooks: \($0)" }
    ///
    /// Covers the installer too, against fixtures in a temp directory. The user's
    /// real `~/.claude/settings.json` is read once at entry and compared at exit:
    /// if anything here ever writes to it, this check fails loudly rather than the
    /// user discovering it.
    static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let realSettings = ClaudeHookInstaller.defaultSettingsURL
        let realBefore = try? Data(contentsOf: realSettings)

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        func event(
            _ name: String,
            extra: [String: String] = [:],
            objects: [String: JSONValue] = [:],
            header: String? = nil
        ) -> HookEvent? {
            var payload: [String: JSONValue] = [
                "hook_event_name": .string(name),
                "session_id": .string("7eb7c63d-b182-41a5-bd01-fadc23af2e04"),
                "transcript_path": .string("/tmp/t.jsonl"),
                "cwd": .string("/tmp"),
                "permission_mode": .string("default"),
                "effort": .object(["level": .string("high")]),
            ]
            for (k, v) in extra { payload[k] = .string(v) }
            for (k, v) in objects { payload[k] = v }
            guard let body = try? JSONValue.object(payload).canonicalData() else { return nil }
            let data = header.map { Data("\($0)\n".utf8) + body } ?? body
            return HookEvent.parse(data, observedAt: t0)
        }

        // 1. Every event name the CLI can emit is accounted for, and nothing in the
        //    table is a name the CLI does not have. No silent default anywhere.
        for name in knownEventNames where dispositions[name] == nil {
            failures.append("event '\(name)' has no disposition")
        }
        for name in dispositions.keys where !knownEventNames.contains(name) {
            failures.append("disposition for '\(name)', which is not a CLI event name")
        }
        check("event list should hold 31 names", knownEventNames.count == 31)

        // 2. Nothing the table can produce is outside what the engine will accept
        //    from this source, or the reading is rejected at ingest.
        let reportable = StateSource.claudeHooks.reportableStates
        for (name, disposition) in dispositions {
            if case .state(let state) = disposition, !reportable.contains(state) {
                failures.append("'\(name)' maps to \(state.rawValue), which claudeHooks cannot report")
            }
        }

        // 3. The spike's table, event by event.
        let expected: [String: AgentState] = [
            "UserPromptSubmit": .running, "PreToolUse": .running,
            "PostToolUse": .running, "PostToolBatch": .running,
            "Stop": .complete, "PermissionRequest": .needsInput,
            "StopFailure": .error, "PostToolUseFailure": .error,
        ]
        for (name, state) in expected {
            guard let e = event(name) else {
                failures.append("could not build a \(name) fixture")
                continue
            }
            check("\(name) should map to \(state.rawValue), got \(String(describing: e.outcome))", e.outcome == .state(state))
        }

        // 4. Slot lifecycle, with the discriminators the registry needs.
        if let start = event("SessionStart", extra: ["source": "resume"], header: "vcm\tpid=5409\tterm=ghostty\tentry=cli") {
            check("SessionStart opens the slot", start.outcome == .openSlot(source: "resume"))
            check("SessionStart keeps its source", start.source == "resume")
            check("SessionStart yields CLAUDE_PID", start.claudePID == 5409)
            check("SessionStart yields TERM_PROGRAM", start.termProgram == "ghostty")
        } else {
            failures.append("could not build a SessionStart fixture")
        }
        if let end = event("SessionEnd", extra: ["reason": "other"]) {
            check("SessionEnd closes the slot", end.outcome == .closeSlot(reason: "other"))
        } else {
            failures.append("could not build a SessionEnd fixture")
        }

        // 5. G4: anything carrying agent_id moves nothing, whatever its name. The
        //    SubagentStop that landed 3.8s after the main Stop is the case this
        //    stops from thrashing the slot.
        for name in knownEventNames {
            guard let e = event(name, extra: ["agent_id": "sub-1", "agent_type": "general-purpose", "source": "startup", "notification_type": "idle_prompt"]) else {
                failures.append("could not build a subagent \(name) fixture")
                continue
            }
            if case .ignored = e.outcome {} else {
                failures.append("\(name) with agent_id produced \(String(describing: e.outcome))")
            }
        }
        // agent_type alone is NOT a subagent mark: it is set on the main thread of
        // an --agent session, so filtering on it would blind us to whole sessions.
        if let mainThread = event("Stop", extra: ["agent_type": "general-purpose"]) {
            check("agent_type alone must not be filtered", mainThread.outcome == .state(.complete))
        }

        // 6. Notification is a signal for exactly one of its eleven types.
        for type in ["permission_prompt", "auth_success", "agent_completed", "push_notification"] {
            guard let e = event("Notification", extra: ["notification_type": type]) else { continue }
            if case .ignored = e.outcome {} else {
                failures.append("Notification(\(type)) produced \(String(describing: e.outcome))")
            }
        }
        if let bare = event("Notification") {
            if case .ignored = bare.outcome {} else {
                failures.append("Notification with no type produced \(String(describing: bare.outcome))")
            }
        }
        if let idle = event("Notification", extra: ["notification_type": "idle_prompt"]) {
            check("Notification(idle_prompt) is idle", idle.outcome == .state(.idle))
        }

        // 7. PermissionRequest keeps the payload the accept/reject keys act on.
        let suggestions = JSONValue.array([.object([
            "type": .string("addRules"), "behavior": .string("allow"),
            "destination": .string("localSettings"),
            "rules": .array([.object([
                "toolName": .string("Bash"),
                "ruleContent": .string("/bin/echo permission-probe *"),
            ])]),
        ])])
        if let permission = event(
            "PermissionRequest",
            extra: ["tool_name": "Bash"],
            objects: [
                "tool_input": .object([
                    "command": .string("/bin/echo permission-probe"),
                    "description": .string("Echo a test string"),
                ]),
                "permission_suggestions": suggestions,
            ]
        ) {
            check("PermissionRequest is needsInput", permission.outcome == .state(.needsInput))
            check("PermissionRequest keeps tool_name", permission.toolName == "Bash")
            check(
                "PermissionRequest keeps tool_input",
                permission.toolInput?["command"]?.stringValue == "/bin/echo permission-probe"
            )
            check("PermissionRequest keeps permission_suggestions", permission.permissionSuggestions == suggestions)
            check("PermissionRequest keeps effort level", permission.effortLevel == "high")
        } else {
            failures.append("could not build a PermissionRequest fixture")
        }

        // 8. An event from a newer CLI is ignored, not guessed at.
        if let future = event("SomeFutureEvent") {
            if case .ignored = future.outcome {} else {
                failures.append("an unknown event produced \(String(describing: future.outcome))")
            }
        } else {
            failures.append("an unknown event name should still parse")
        }

        // 9. Malformed input is dropped, never thrown and never half-read.
        let malformed: [String: Data] = [
            "empty": Data(),
            "not json": Data("this is not json".utf8),
            "truncated": Data(#"{"hook_event_name":"Stop","session_id":"a"#.utf8),
            "array": Data(#"["Stop"]"#.utf8),
            "no session_id": Data(#"{"hook_event_name":"Stop"}"#.utf8),
            "no event name": Data(#"{"session_id":"a"}"#.utf8),
            "empty session_id": Data(#"{"hook_event_name":"Stop","session_id":""}"#.utf8),
            "wrong types": Data(#"{"hook_event_name":42,"session_id":true}"#.utf8),
            "header only": Data("vcm\tpid=1\n".utf8),
            "header then garbage": Data("vcm\tpid=1\n{{{".utf8),
        ]
        for (label, data) in malformed {
            check("malformed payload '\(label)' must be dropped", HookEvent.parse(data, observedAt: t0) == nil)
        }

        // 10. Spool round trip: mtime order wins over filename order, and files are
        //     consumed. Names are chosen so lexical order is the WRONG order.
        let fixtures = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcm-hooks-selfcheck-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixtures) }
        let spoolDir = fixtures.appendingPathComponent("spool", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: spoolDir, withIntermediateDirectories: true)
            let order = [("zzz", "PreToolUse", t0), ("aaa", "PermissionRequest", t0.addingTimeInterval(0.001))]
            for (name, eventName, mtime) in order {
                let body = try JSONValue.object([
                    "hook_event_name": .string(eventName),
                    "session_id": .string("s"),
                ]).canonicalData()
                let url = spoolDir.appendingPathComponent("\(name).json")
                try body.write(to: url)
                try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
            }
            // A partial write under the temp name must be invisible.
            try Data("{".utf8).write(to: spoolDir.appendingPathComponent("tmp.ABCDEF"))

            let source = ClaudeHookSource(spoolDirectory: spoolDir)
            let drained = source.drainNow()
            check(
                "spool drains in mtime order, not filename order",
                drained.map(\.name) == ["PreToolUse", "PermissionRequest"]
            )
            check("spool stamps observedAt from the file", drained.first?.observedAt == t0)
            check("spool consumes what it read", source.drainNow().isEmpty)
            check(
                "an in-flight temp file is left alone",
                FileManager.default.fileExists(atPath: spoolDir.appendingPathComponent("tmp.ABCDEF").path)
            )
            check("draining a directory that does not exist is safe", ClaudeHookSource(spoolDirectory: fixtures.appendingPathComponent("nope")).drainNow().isEmpty)
        } catch {
            failures.append("spool fixture setup failed: \(error)")
        }

        failures += ClaudeHookInstaller.selfCheckFailures(in: fixtures)

        // The invariant that matters most in this file.
        let realAfter = try? Data(contentsOf: realSettings)
        check("the self-check must not touch the real ~/.claude/settings.json", realBefore == realAfter)

        return failures
    }
}
