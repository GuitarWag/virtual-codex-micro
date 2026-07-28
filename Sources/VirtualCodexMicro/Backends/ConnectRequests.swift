import Foundation

/// A session asking to be put on a key, from inside itself.
///
/// Every discovery path this app has is an outside-in guess: parse `ps` argv, read
/// a cmux resume checkpoint, wait for an event. Each one has a hole — a bare
/// `claude` carries no session id, a new session has no checkpoint, an idle one
/// emits no events, and a pid claimed by two surfaces resolves to neither. The
/// session itself has none of those problems: `CLAUDE_CODE_SESSION_ID` and
/// `CLAUDE_PID` are in its own environment, so it can simply say who it is.
///
/// So this is the inside-out path. A skill run from any session drops a request
/// here; the panel binds it. It also lets a specific slot be asked for, which no
/// amount of discovery can infer — "put this one on key 3" is a preference, not a
/// fact about the system.
///
/// Same spool shape as `ClaudeHookSource`: write a temp file, rename into place,
/// reader takes only `*.json`, so a partial write is never seen. Drained in mtime
/// order for the same reason — two requests a millisecond apart must not swap.
public struct ConnectRequest: Sendable, Equatable {
    public let sessionID: String
    public let pid: Int32?
    public let cwd: String?
    /// 1-based as the user typed it; `nil` means "any free key".
    public let requestedSlot: Int?
    public let surfaceID: String?
    /// A colour to force on this session's key, for testing. Expires; see
    /// `StateSource.manualTest`.
    public let forcedState: AgentState?
    public let receivedAt: Date

    /// Zero-based index, validated against the real slot count. A request naming
    /// slot 9 on an eight-key panel is a typo, not an instruction, and is treated
    /// as "any free key" rather than rejected outright — the user's intent to
    /// connect is unambiguous even when their number is wrong.
    public func slotIndex(slotCount: Int) -> Int? {
        guard let requestedSlot, requestedSlot >= 1, requestedSlot <= slotCount else { return nil }
        return requestedSlot - 1
    }

    /// Colour words as well as state names, because "green" is what someone types
    /// when testing and `complete` is what the model calls it. The words follow the
    /// reference device's own legend: idle white, thinking blue, complete green,
    /// needs input amber, error red.
    public static func state(named text: String) -> AgentState? {
        let key = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch key {
        case "white", "grey", "gray", "idle": return .idle
        case "blue", "running", "thinking", "working": return .running
        case "green", "complete", "done", "finished": return .complete
        case "amber", "yellow", "orange", "needsinput", "needs-input", "waiting": return .needsInput
        case "red", "error", "failed", "failure": return .error
        case "hatched", "unknown", "lost": return .unknown
        case "empty", "off", "unassigned", "clear": return .unassigned
        default: return AgentState(rawValue: key)
        }
    }

    public static let defaultDirectory = ClaudeHookInstaller.supportDirectory
        .appendingPathComponent("connect-requests", isDirectory: true)

    /// Parses one request file. Returns nil rather than throwing: a malformed
    /// request must not take down the watcher, and there is nobody to report a
    /// throw to.
    public static func parse(_ data: Data, receivedAt: Date) -> ConnectRequest? {
        guard let root = JSONValue.parse(data)?.objectValue,
              let sessionID = root["session_id"]?.stringValue,
              !sessionID.isEmpty
        else { return nil }

        return ConnectRequest(
            sessionID: sessionID,
            pid: root["pid"]?.intValue.map(Int32.init),
            cwd: root["cwd"]?.stringValue,
            requestedSlot: root["slot"]?.intValue,
            surfaceID: root["surface_id"]?.stringValue,
            forcedState: root["state"]?.stringValue.flatMap(state(named:)),
            receivedAt: receivedAt
        )
    }

    /// One drain. No watcher, no timer — the coordinator already polls, and a
    /// second timer would be a second thing to get wrong.
    public static func drain(directory: URL = defaultDirectory) -> [ConnectRequest] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }

        let files = names
            .filter { $0.hasSuffix(".json") }
            .map { directory.appendingPathComponent($0) }
            .compactMap { url -> (URL, Date)? in
                let modified = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
                return (url, modified ?? .distantPast)
            }
            // mtime, not filename: `mktemp` names sort arbitrarily, and a request
            // written second must not be applied first.
            .sorted { $0.1 < $1.1 }

        var requests: [ConnectRequest] = []
        for (url, modified) in files {
            defer { try? fm.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let request = parse(data, receivedAt: modified)
            else { continue }
            requests.append(request)
        }
        return requests
    }

    // MARK: - Self check

    public static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let full = #"{"session_id":"abc","pid":4242,"cwd":"/tmp/x","slot":3,"surface_id":"S-1"}"#
        let parsed = parse(Data(full.utf8), receivedAt: now)
        check("a full request did not parse", parsed != nil)
        check("session id lost", parsed?.sessionID == "abc")
        check("pid lost", parsed?.pid == 4242)
        check("surface id lost", parsed?.surfaceID == "S-1")

        // 1-based in, 0-based out. Getting this wrong would put a session on the
        // key next to the one the user named, which is worse than ignoring them.
        check("slot 3 did not map to index 2", parsed?.slotIndex(slotCount: 8) == 2)
        check("slot 1 did not map to index 0",
              parse(Data(#"{"session_id":"a","slot":1}"#.utf8), receivedAt: now)?
                  .slotIndex(slotCount: 8) == 0)
        check("slot 8 did not map to index 7",
              parse(Data(#"{"session_id":"a","slot":8}"#.utf8), receivedAt: now)?
                  .slotIndex(slotCount: 8) == 7)

        // Out of range and nonsense degrade to "any free key", because the intent
        // to connect is unambiguous even when the number is not.
        for bad in ["0", "9", "-1", "999"] {
            let request = parse(Data(#"{"session_id":"a","slot":\#(bad)}"#.utf8), receivedAt: now)
            check("slot \(bad) was not treated as any-free-key",
                  request != nil && request?.slotIndex(slotCount: 8) == nil)
        }
        check("a request with no slot did not mean any-free-key",
              parse(Data(#"{"session_id":"a"}"#.utf8), receivedAt: now)?
                  .slotIndex(slotCount: 8) == nil)

        // Malformed input must yield nil, never a crash and never a request with an
        // empty session id — binding a slot to "" would take a key out of service.
        for bad in ["", "{", "[]", "null", #"{"pid":1}"#, #"{"session_id":""}"#, "not json at all"] {
            check("malformed request \(bad.isEmpty ? "<empty>" : bad) produced a request",
                  parse(Data(bad.utf8), receivedAt: now) == nil)
        }

        // Colour words and state names both resolve, and the mapping follows the
        // reference legend rather than being invented per call site.
        let expected: [(String, AgentState)] = [
            ("green", .complete), ("GREEN", .complete), ("complete", .complete),
            ("blue", .running), ("thinking", .running), ("running", .running),
            ("amber", .needsInput), ("yellow", .needsInput), ("needsInput", .needsInput),
            ("red", .error), ("error", .error),
            ("white", .idle), ("idle", .idle),
            ("unknown", .unknown), ("hatched", .unknown),
            ("empty", .unassigned),
        ]
        for (word, want) in expected {
            check("\(word) did not resolve to \(want.rawValue), got \(state(named: word)?.rawValue ?? "nil")",
                  state(named: word) == want)
        }
        check("a nonsense colour resolved to something", state(named: "octarine") == nil)
        check("every state is reachable by its own raw value",
              AgentState.allCases.allSatisfy { state(named: $0.rawValue) == $0 })
        check("a forced state did not parse from a request",
              parse(Data(#"{"session_id":"a","state":"green"}"#.utf8), receivedAt: now)?
                  .forcedState == .complete)
        check("a request with no state forced one",
              parse(Data(#"{"session_id":"a"}"#.utf8), receivedAt: now)?.forcedState == nil)
        // The expiry is what stops a test leaving a key lying for good.
        check("the manual test source does not expire",
              StateSource.manualTest.stalenessThreshold > 0
                  && StateSource.manualTest.stalenessThreshold <= 120)

        // Drain: mtime order, files consumed, non-json ignored.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("vcm-connect-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        for (index, id) in ["first", "second", "third"].enumerated() {
            let url = scratch.appendingPathComponent("r\(2 - index).json")   // reverse-sorted names
            try? Data(#"{"session_id":"\#(id)"}"#.utf8).write(to: url)
            try? FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(Double(index))], ofItemAtPath: url.path
            )
        }
        try? Data("ignore me".utf8).write(to: scratch.appendingPathComponent("notes.txt"))

        let drained = drain(directory: scratch)
        check("drain did not return three requests, got \(drained.count)", drained.count == 3)
        check("drain ignored mtime order: \(drained.map(\.sessionID))",
              drained.map(\.sessionID) == ["first", "second", "third"])
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? []
        check("drain left json files behind", !leftover.contains { $0.hasSuffix(".json") })
        check("drain removed a non-json file it should not touch", leftover.contains("notes.txt"))
        check("draining an empty directory was not empty", drain(directory: scratch).isEmpty)

        return failures
    }
}
