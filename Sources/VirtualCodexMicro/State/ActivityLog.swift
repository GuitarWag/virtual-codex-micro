import Foundation
import os

// MARK: - Privacy
//
// **This log never leaves the machine.** No network client, no URLSession, no
// analytics, no crash-reporter attachment, no file on disk. It is in-memory only
// and dies with the process. That is a hard constraint, not a default: entries
// carry session ids, slot numbers, source names and free-form reasons taken from
// the user's real work, and the fuller view alongside them shows repo paths,
// branches and session titles. Anything that would transmit or persist this
// content needs its own consent decision, so the buffer deliberately offers no
// export, no encoder and no `Codable` conformance to make that accidental.

/// One thing that happened, or one thing we noticed *not* happening.
///
/// This exists because the panel can be legitimately wrong, and the spikes are
/// specific about how: a hook listener can go quiet, transcript inference can
/// abstain to `unknown`, a pending permission prompt is structurally invisible to
/// tailing, and an injected keystroke can land with nothing confirming it. When a
/// user says "it said running but it was waiting", this is the difference between
/// diagnosable and mysterious — so an entry records the source and its confidence,
/// not just the outcome.
public struct ActivityEntry: Identifiable, Sendable, Equatable {

    /// Coarse class, for the icon and tint the views pick. The detail lives in
    /// `Event`; this is only what a glance needs.
    public enum Kind: String, Sendable, CaseIterable {
        case stateChange
        case stalenessExpiry
        case action
        case note
    }

    /// What became of a dispatched command.
    ///
    /// `unconfirmed` is the whole reason this type is not a `Bool`. Per the plan's
    /// decision on task 023, `PermissionDenied` never fired across 12 spike
    /// sessions, so an injected reject has no proven confirming event: after a
    /// bounded wait we drive the key to `unknown`, and the log has to say the
    /// action was never confirmed rather than imply it worked.
    public enum ActionOutcome: Sendable, Equatable {
        /// Written to the session, nothing has confirmed it yet.
        case sent
        /// A real event confirmed delivery — name it, so the claim is checkable.
        case confirmed(by: String)
        /// The bounded wait elapsed with no confirming event.
        case unconfirmed(after: TimeInterval)
        case failed(String)
    }

    public enum Event: Sendable, Equatable {
        /// A source reported a state and it differed from what we were showing.
        case stateChange(
            from: AgentState,
            to: AgentState,
            source: String,
            confidence: StateConfidence,
            reason: String
        )

        /// **The most valuable line in the log.** A reading aged past its
        /// source's staleness threshold and nothing fresher took over, so the key
        /// went to `unknown`. A silence here would leave the user watching a key
        /// change colour for no stated reason, which is exactly the drift the
        /// state model exists to admit to.
        case stalenessExpiry(was: AgentState, source: String, silentFor: TimeInterval)

        /// A dispatched command and where it got to.
        case action(AgentCommand, ActionOutcome)

        /// Anything else worth a line: a hook receiver dropping its connection, a
        /// source declaring it cannot see `needsInput`, a reconnect verdict.
        case note(String)
    }

    /// Assigned by the log on insert, strictly increasing, never reused. Doubles
    /// as `id` and as the newest-first sort key — two entries can share a
    /// timestamp, and stable ordering in a diagnostic log is not optional.
    public internal(set) var sequence: UInt64 = 0

    /// When the *evidence* happened, supplied by the caller. Never read from a
    /// wall clock in here, so the self check is deterministic and a source can
    /// stamp an entry with the transcript record's own time.
    public let at: Date
    /// Slot 0-5, or `nil` for a session with no key (overflow, or app-level).
    public let slot: Int?
    /// Empty for entries about the app rather than one session.
    public let sessionID: String
    public let event: Event

    public var id: UInt64 { sequence }

    public init(at: Date, slot: Int? = nil, sessionID: String = "", event: Event) {
        self.at = at
        self.slot = slot
        self.sessionID = sessionID
        self.event = event
    }

    public var kind: Kind {
        switch event {
        case .stateChange: .stateChange
        case .stalenessExpiry: .stalenessExpiry
        case .action: .action
        case .note: .note
        }
    }

    /// The `AgentState` this entry should be tinted as, so the strip uses the same
    /// vocabulary as the keys rather than inventing a second palette. An
    /// unconfirmed action tints `unknown` because that is where it leaves the key.
    public var tintState: AgentState {
        switch event {
        case let .stateChange(_, to, _, _, _): to
        case .stalenessExpiry: .unknown
        case let .action(_, outcome):
            switch outcome {
            case .sent: .running
            case .confirmed: .complete
            case .unconfirmed: .unknown
            case .failed: .error
            }
        case .note: .unknown
        }
    }

    /// Local wall-clock time of the entry, `HH:MM:SS`. Built from components
    /// rather than a `DateFormatter` because a formatter is neither `Sendable` nor
    /// free, and this is called once per visible row.
    public var clockText: String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: at)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Which key or session this is about. Ids are truncated: the strip has ~412pt
    /// of width and a full uuid would crowd out the part that carries meaning.
    public var subject: String {
        switch (slot, sessionID.isEmpty) {
        case let (slot?, false): "slot \(slot + 1) · \(sessionID.prefix(8))"
        case let (slot?, true): "slot \(slot + 1)"
        case (nil, false): "session \(sessionID.prefix(8))"
        case (nil, true): "app"
        }
    }

    /// The single line a user reads, in the strip and in the full list alike.
    /// One string, so the two surfaces cannot drift into telling different
    /// stories, and so the self check can assert on the wording itself.
    public var description: String { "\(subject): \(eventText)" }

    private var eventText: String {
        switch event {
        case let .stateChange(from, to, source, confidence, reason):
            var text = "\(from.label) → \(to.label) · \(source) (\(Self.name(confidence)))"
            if !reason.isEmpty { text += " · \(reason)" }
            return text

        case let .stalenessExpiry(was, source, silentFor):
            return "\(source) went quiet for \(Self.seconds(silentFor)) · "
                + "\(was.label) → \(AgentState.unknown.label), no fresher source"

        case let .action(command, outcome):
            let verb = Self.name(command)
            switch outcome {
            case .sent:
                return "\(verb) sent, awaiting confirmation"
            case let .confirmed(by):
                return "\(verb) sent, confirmed by \(by)"
            case let .unconfirmed(after):
                // Wording is load-bearing. It must not read as an outcome: no
                // "done", no "sent successfully". The action was written and
                // nothing witnessed it, so the key is grey and the line says why.
                return "\(verb) sent, unconfirmed after \(Self.seconds(after))"
                    + " — no confirming event, state set to \(AgentState.unknown.label)"
            case let .failed(reason):
                return "\(verb) failed: \(reason)"
            }

        case let .note(text):
            return text
        }
    }

    private static func name(_ confidence: StateConfidence) -> String {
        switch confidence {
        case .inferred: "inferred"
        case .reported: "reported"
        }
    }

    /// Prompt text is deliberately not logged — the command name is enough to
    /// diagnose dispatch, and a prompt is the most sensitive thing a user types.
    private static func name(_ command: AgentCommand) -> String {
        switch command {
        case .focus: "focus"
        case .approve: "approve"
        case .reject: "reject"
        case .newSession: "new session"
        case .sendPrompt: "prompt"
        case let .setEffort(step): "effort \(step)"
        }
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.1fs", interval)
    }
}

// MARK: - The log

/// Bounded in-memory ring buffer of everything we saw and everything we noticed
/// we did not see.
///
/// **Isolation.** A `final class` conforming to `Sendable` with every mutable
/// field inside one `OSAllocatedUnfairLock`. That lock type is itself `Sendable`
/// over a `Sendable` state, so the conformance is checked by the compiler rather
/// than promised by an `@unchecked` annotation.
///
/// Why a lock and not an actor: the producers are a hook receiver, an FSEvents
/// callback and a PTY read loop, none of which is an async context, and the
/// consumer is a SwiftUI `body`, which cannot await. An actor would force a
/// `Task` hop at every one of those boundaries — per-event allocation on a read
/// loop, and worse, arrival order scrambled in a log whose whole job is to say
/// what happened in what order. `Mutex` from `Synchronization` would be the modern
/// spelling but is macOS 15+, and the package targets macOS 14.
///
/// The critical sections are short array operations with no callouts, so nothing
/// can reenter or deadlock, and no producer ever blocks on the UI.
public final class ActivityLog: Sendable {

    /// 512 entries.
    ///
    /// Sizing, not a round number: the useful hook events land in 6-31ms and a
    /// busy session produces a handful of transitions per turn, so six sessions
    /// under heavy use generate a few hundred entries an hour. 512 therefore
    /// covers roughly the last hour of real work — the window a "it said running
    /// but it was waiting" complaint actually refers to — for about 150KB at
    /// ~300 bytes an entry. Unbounded is not on the table: this runs for days on
    /// a floating panel, and an audit log that grows until it is the largest
    /// thing in the process is its own bug.
    public static let defaultCapacity = 512

    private struct Buffer: Sendable {
        /// Oldest first. Reversed on read; see `entries(limit:)`.
        var entries: [ActivityEntry] = []
        /// Evicted count, surfaced so the full view can say "N earlier dropped".
        /// The plan's rule against silent truncation applies here too.
        var dropped: Int = 0
        var nextSequence: UInt64 = 1
    }

    public let capacity: Int
    private let buffer: OSAllocatedUnfairLock<Buffer>

    public init(capacity: Int = ActivityLog.defaultCapacity) {
        self.capacity = max(1, capacity)
        buffer = OSAllocatedUnfairLock(initialState: Buffer())
    }

    /// Append, evicting oldest-first past `capacity`. Safe from any thread.
    public func record(_ entry: ActivityEntry) {
        buffer.withLock { buffer in
            var stamped = entry
            stamped.sequence = buffer.nextSequence
            buffer.nextSequence += 1
            buffer.entries.append(stamped)
            let excess = buffer.entries.count - capacity
            if excess > 0 {
                buffer.dropped += excess
                buffer.entries.removeFirst(excess)
            }
        }
    }

    /// Newest first, which is the order both views render. `limit` takes the most
    /// recent N, so the strip asks for 3 and pays for 3.
    ///
    /// ponytail: `removeFirst` and this reversal are O(capacity). At 512 entries
    /// and a UI that reads a few times a second that is noise; a head index would
    /// be the fix if the capacity ever grows by an order of magnitude.
    public func entries(limit: Int? = nil) -> [ActivityEntry] {
        buffer.withLock { buffer in
            let newestFirst = buffer.entries.reversed()
            guard let limit else { return Array(newestFirst) }
            return Array(newestFirst.prefix(max(0, limit)))
        }
    }

    /// One session's history, for the popover's "open the log filtered to this
    /// session" action in task 026.
    public func entries(forSession sessionID: String, limit: Int? = nil) -> [ActivityEntry] {
        buffer.withLock { buffer in
            let matching = buffer.entries.reversed().filter { $0.sessionID == sessionID }
            guard let limit else { return matching }
            return Array(matching.prefix(max(0, limit)))
        }
    }

    public var count: Int { buffer.withLock { $0.entries.count } }

    /// Entries evicted since launch. Non-zero means the view must say so.
    public var dropped: Int { buffer.withLock { $0.dropped } }

    public func clear() {
        buffer.withLock { buffer in
            buffer.entries.removeAll(keepingCapacity: true)
            buffer.dropped = 0
        }
    }
}

// MARK: - Self check

public extension ActivityLog {
    /// Human-readable failures, empty when healthy. Wire into `SelfCheck` with:
    ///
    ///     failures += ActivityLog.selfCheckFailures().map { "activity: \($0)" }
    ///
    /// Every timestamp is injected. Nothing here reads a clock, so a slow machine
    /// cannot make it flake.
    static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)

        // 1. Bounded, and it evicts the oldest. Filled well past capacity, then
        //    asserted on both the count and the disappearance of entry one —
        //    a buffer that kept the head and dropped the tail would pass a
        //    count-only check while showing the user last Tuesday.
        let ring = ActivityLog(capacity: 8)
        for index in 0 ..< 20 {
            ring.record(
                ActivityEntry(
                    at: t0.addingTimeInterval(Double(index)),
                    slot: 0, sessionID: "ring-session",
                    event: .note("event \(index)")
                )
            )
        }
        let kept = ring.entries()
        check("ring holds \(kept.count) entries, capacity is 8", kept.count == 8)
        check("ring exceeded its capacity via count", ring.count == 8)
        check("oldest entry survived eviction", !kept.contains { $0.sequence == 1 })
        check(
            "eviction was not oldest-first (kept sequences \(kept.map(\.sequence)))",
            kept.map(\.sequence) == Array((13 ... 20).reversed())
        )
        check("evictions were not counted", ring.dropped == 12)
        check("clear() left entries behind", { ring.clear(); return ring.count == 0 }())

        let log = ActivityLog()

        // 2. A staleness expiry is an entry, not a silence. This is the line that
        //    explains why a key went grey, so "nothing was recorded" is the
        //    failure being guarded against.
        let quiet = StateSource.claudeTranscript
        log.record(
            ActivityEntry(
                at: t0.addingTimeInterval(quiet.stalenessThreshold + 1),
                slot: 2, sessionID: "expiring-session",
                event: .stalenessExpiry(
                    was: .running, source: quiet.id, silentFor: quiet.stalenessThreshold + 1
                )
            )
        )
        let expiry = log.entries(limit: 1).first
        check("a staleness expiry recorded nothing", expiry != nil)
        if let expiry {
            check("expiry entry is not classed as one", expiry.kind == .stalenessExpiry)
            check(
                "expiry does not say which source went quiet: '\(expiry.description)'",
                expiry.description.contains(quiet.id)
            )
            check(
                "expiry does not say the key went unknown: '\(expiry.description)'",
                expiry.description.contains(AgentState.unknown.label)
            )
            check(
                "expiry does not name the state it replaced: '\(expiry.description)'",
                expiry.description.contains(AgentState.running.label)
            )
            check("expiry is not tinted unknown", expiry.tintState == .unknown)
        }

        // 3. An unconfirmed action is recorded as unconfirmed and must never read
        //    as success. Asserted on the rendered string, because that sentence is
        //    the whole deliverable — a correct enum with a description saying
        //    "reject done" would be the bug.
        let unconfirmed = ActivityEntry(
            at: t0, slot: 3, sessionID: "reject-session",
            event: .action(.reject, .unconfirmed(after: 3))
        )
        let confirmed = ActivityEntry(
            at: t0, slot: 3, sessionID: "reject-session",
            event: .action(.approve, .confirmed(by: "PostToolUse"))
        )
        log.record(unconfirmed)
        log.record(confirmed)

        let text = unconfirmed.description
        check("unconfirmed action does not say so: '\(text)'", text.contains("unconfirmed"))
        check(
            "unconfirmed action does not say the state went unknown: '\(text)'",
            text.contains(AgentState.unknown.label)
        )
        check("unconfirmed action does not name the command: '\(text)'", text.contains("reject"))
        // "done" is `AgentState.complete.label`, so it is exactly the word a user
        // would read as "it worked".
        for claim in ["success", "succeeded", "confirmed by", "delivered", "applied", "done", "complete"] {
            check(
                "unconfirmed action claims '\(claim)': '\(text)'",
                !text.lowercased().contains(claim)
            )
        }
        check(
            "unconfirmed and confirmed actions read identically",
            text != confirmed.description
        )
        check(
            "a genuinely confirmed action does not name its witness",
            confirmed.description.contains("confirmed by PostToolUse")
        )
        check("unconfirmed action is not tinted unknown", unconfirmed.tintState == .unknown)
        check("confirmed action is tinted unknown", confirmed.tintState != .unknown)
        // And it has to be visible in the strip, not just stored.
        check(
            "the unconfirmed action is not visible in a 3-row strip",
            log.entries(limit: 3).contains { $0.description == text }
        )

        // 4. Newest first, as both views assume. Timestamps ascend on insert, so a
        //    newest-first result has descending times and descending sequences.
        let ordered = log.entries()
        check("log is not ordered newest-first", ordered.map(\.sequence) == ordered.map(\.sequence).sorted(by: >))
        check(
            "newest entry is not the last one recorded",
            ordered.first?.description == confirmed.description
        )
        check("limit(1) did not return the newest entry", log.entries(limit: 1).first?.id == ordered.first?.id)
        check("limit(0) returned entries", log.entries(limit: 0).isEmpty)
        check(
            "session filter leaked another session",
            log.entries(forSession: "reject-session").allSatisfy { $0.sessionID == "reject-session" }
        )
        check("session filter lost entries", log.entries(forSession: "reject-session").count == 2)

        // 5. Concurrent producers lose nothing. Real threads rather than one
        //    serial queue, because that is what a hook receiver, an FSEvents
        //    callback and a PTY read loop actually are.
        let producers = 8
        let each = 40
        let concurrent = ActivityLog(capacity: 512)
        DispatchQueue.concurrentPerform(iterations: producers) { producer in
            for index in 0 ..< each {
                concurrent.record(
                    ActivityEntry(
                        at: t0.addingTimeInterval(Double(index)),
                        slot: producer % PanelLayout.agentKeyCount,
                        sessionID: "p\(producer)",
                        event: .note("concurrent \(index)")
                    )
                )
            }
        }
        let total = producers * each
        let all = concurrent.entries()
        check("concurrent append lost entries: \(all.count) of \(total)", all.count == total)
        check("concurrent append dropped entries under capacity", concurrent.dropped == 0)
        check(
            "concurrent append reused sequence numbers",
            Set(all.map(\.sequence)).count == total
        )
        check(
            "concurrent sequences are not 1...\(total)",
            all.map(\.sequence).max() == UInt64(total) && all.map(\.sequence).min() == 1
        )
        for producer in 0 ..< producers {
            check(
                "producer \(producer) lost entries",
                concurrent.entries(forSession: "p\(producer)").count == each
            )
        }

        return failures
    }
}
