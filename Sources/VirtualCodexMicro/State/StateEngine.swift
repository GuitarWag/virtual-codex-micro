import Foundation

/// Whether the process behind a session still exists. Deliberately *not* an
/// `AgentState`: the tailing spike's finding is that a graceful quit, a `Ctrl-C`,
/// a crash and a session sitting at its prompt all leave an identical transcript
/// tail, so liveness can only come from the `ps` join alongside. Folding it into
/// the state would make `idle` and `crashed` the same colour, which the plan
/// names as risk #1.
public enum Liveness: String, Sendable, Codable {
    case alive
    case dead
    /// No liveness join has spoken for this session. Permissive: we do not have
    /// evidence of death, so a state reading passes through unchanged.
    case unknown
}

/// One thing that can tell us about session state, and — the part that matters —
/// the limits of what it is able to see.
///
/// `reportableStates` is the whole reason this type exists. Transcript tailing
/// cannot observe a pending permission prompt at all: nothing is written between
/// a `tool_use` and its `tool_result`, so a `Bash` call running for 100 minutes
/// and an approval prompt open for 145 minutes produce byte-identical tails. A
/// source that omits `.needsInput` here is saying "I cannot see that", which is a
/// different claim from "it is not happening". Without the distinction the amber
/// key silently never lights and nothing looks broken.
public struct StateSource: Sendable, Identifiable, Equatable {
    public let id: String
    public let confidence: StateConfidence
    /// The source's entire vocabulary. Anything outside it is rejected on ingest,
    /// and anything no *fresh* source declares lands in `Resolution.unobservable`.
    public let reportableStates: Set<AgentState>
    /// How long a reading from this source stays believable, measured from when
    /// the *evidence* was produced — not from when we processed it. That
    /// distinction is what makes the measured silence numbers usable: the tailer
    /// stamps a reading with the newest transcript record's time, so "quiet"
    /// means the session was quiet, not that our poller was.
    public let stalenessThreshold: TimeInterval

    public init(
        id: String,
        confidence: StateConfidence,
        reportableStates: Set<AgentState>,
        stalenessThreshold: TimeInterval
    ) {
        self.id = id
        self.confidence = confidence
        self.reportableStates = reportableStates
        self.stalenessThreshold = stalenessThreshold
    }

    // MARK: - The sources that actually exist

    /// Hook events. The only source that can turn a key amber.
    ///
    /// 15s because this is a push channel that fires at the moment of a call, and
    /// the adapter re-affirms on the same 2s `ps` tick the liveness join already
    /// needs — so 15s is seven missed ticks. A hook source that stops re-affirming
    /// loses its vote by design: an `idle` from a receiver that died is exactly the
    /// stale colour this engine exists to prevent.
    public static let claudeHooks = StateSource(
        id: "claude.hooks",
        confidence: .reported,
        reportableStates: [.idle, .running, .complete, .needsInput, .error, .unknown],
        stalenessThreshold: 15
    )

    /// Transcript tailing. Scoped to `running`, `idle`, `complete`, `error` and
    /// abstention, per task 022 — the `AskUserQuestion` exception that could
    /// technically yield `needsInput` is deliberately dropped, because a source
    /// that reports `needsInput` for one tool in ten is worse than one that
    /// declares it cannot see it at all.
    ///
    /// 90s from the measured within-turn silence: p50 2.2s, p90 10.8s, p99 74s,
    /// 1.2% over 60s, max 8713s. Nothing is appended while the model generates, so
    /// a busy session looks quiet; sitting above p99 keeps ~99% of real turns from
    /// being greyed mid-response, and the max shows no threshold is ever
    /// never-wrong. The cost lands on abstention, which is the safe direction: an
    /// abandoned session holds its colour for at most 90s.
    public static let claudeTranscript = StateSource(
        id: "claude.transcript",
        confidence: .inferred,
        reportableStates: [.idle, .running, .complete, .error, .unknown],
        stalenessThreshold: 90
    )

    /// The app's own slot bindings. `unassigned` is not a property of any session
    /// — it means no session is bound — so no provider source may produce it.
    /// Infinite threshold because we are the source: our own bookkeeping cannot
    /// "go quiet", and an empty slot stays empty until something rebinds it.
    public static let appBinding = StateSource(
        id: "app.binding",
        confidence: .reported,
        reportableStates: [.unassigned, .unknown],
        stalenessThreshold: .infinity
    )

    /// The mock backend, which is the only source that can produce every state on
    /// demand. Kept here rather than in `MockBackend` so the engine's own checks
    /// have something omniscient to point at.
    public static func mock(id: String = "mock", stalenessThreshold: TimeInterval = 15) -> StateSource {
        StateSource(
            id: id,
            confidence: .reported,
            reportableStates: Set(AgentState.allCases),
            stalenessThreshold: stalenessThreshold
        )
    }
}

/// One source's claim about one session at one moment.
public struct StateReading: Sendable, Equatable {
    public let sourceID: String
    public let state: AgentState
    /// When the evidence was produced. See `StateSource.stalenessThreshold`.
    public let observedAt: Date

    public init(sourceID: String, state: AgentState, observedAt: Date) {
        self.sourceID = sourceID
        self.state = state
        self.observedAt = observedAt
    }
}

/// What the UI renders, and everything it needs to render it honestly.
public struct Resolution: Sendable, Equatable {
    public let state: AgentState
    public let confidence: StateConfidence
    public let liveness: Liveness
    /// Why this state, in words. Goes in the tooltip and the log; a colour with no
    /// explanation is unfalsifiable.
    public let reason: String
    /// States that no currently-contributing source is *able* to see. `.unknown`
    /// is never in here — the engine can always produce it.
    ///
    /// Non-empty means "we would not know if this were happening". The UI must say
    /// so out loud: if `.needsInput` is in here because the user declined the hook
    /// installer, the panel has to state that waiting is undetectable rather than
    /// leave an amber key that can never light.
    public let unobservable: Set<AgentState>

    public var needsInputObservable: Bool { !unobservable.contains(.needsInput) }

    public init(
        state: AgentState,
        confidence: StateConfidence,
        liveness: Liveness,
        reason: String,
        unobservable: Set<AgentState>
    ) {
        self.state = state
        self.confidence = confidence
        self.liveness = liveness
        self.reason = reason
        self.unobservable = unobservable
    }
}

public enum IngestResult: Sendable, Equatable {
    case accepted
    /// Rejected and logged, never silently swallowed. The reason is human-readable
    /// because the only consumer is a person reading `rejections`.
    case rejected(String)
}

/// Owns the seven-state model and the arbitration between the sources that feed
/// it. Knows nothing about hooks, transcripts, JSONL or `ps` — adapters map their
/// vocabulary in at their own boundary and hand this engine normalized states.
///
/// A value type on purpose. Every resolution is recomputed from the stored
/// readings at the time you ask, so there is no cached "current state" that can
/// drift, and no actor for callers to hop to. Whoever owns the registry owns one
/// of these.
///
/// **Legal transitions.** Every ordered pair of states is legal except as follows,
/// and that permissiveness is deliberate: real sessions jump (running → error →
/// running, needsInput → idle on a rejection, complete → running on a follow-up
/// prompt), and an engine that rejects a legitimate transition is worse than one
/// that accepts a surprising one. What is *not* legal:
///
/// 1. A state outside the reporting source's declared vocabulary — rejected and
///    logged. This is the rule that stops transcript inference from ever asserting
///    `needsInput`, and stops any provider source from claiming `unassigned`. A
///    source outside the vocabulary can still *retract* somebody else's
///    `needsInput` — see `clearNeedsInput`, which is why "I saw the prompt end" does
///    not require the standing to say "a prompt is open".
/// 2. A reading from an unregistered source — rejected and logged, because its
///    confidence and limits are unknown and guessing them is how a low-confidence
///    guess gets rendered as fact.
/// 3. An in-flight state (`idle`, `running`, `complete`, `needsInput`) for a
///    session whose process is gone — normalized to `.unknown` at resolve time
///    with the reason recorded. `error` and `unassigned` survive death, since
///    "it crashed" and "the slot is empty" are both still true afterwards.
/// 4. `unassigned` and any session-bearing state are mutually exclusive, so
///    recording either drops the other. Otherwise a cleared slot would keep the
///    old session's colour, or a rebound slot would stay grey.
public struct StateEngine: Sendable {
    private var sources: [String: StateSource] = [:]
    private var readings: [String: [String: StateReading]] = [:]
    private var liveness: [String: Liveness] = [:]
    /// Rejected ingests, newest last, capped. A ring buffer, not a diagnosis:
    /// anything in here is a bug in an adapter.
    public private(set) var rejections: [String] = []

    private static let rejectionLimit = 32

    public init(sources: [StateSource] = []) {
        for source in sources { self.sources[source.id] = source }
    }

    public mutating func register(_ source: StateSource) {
        sources[source.id] = source
    }

    public var registeredSources: [StateSource] {
        sources.values.sorted { $0.id < $1.id }
    }

    /// States no registered source could ever report, whatever happens. This is
    /// the "amber key is unavailable" signal — a configuration fact, distinct from
    /// `Resolution.unobservable`, which is about who is talking right now.
    public var statesNoSourceCanReport: Set<AgentState> {
        var missing = Set(AgentState.allCases)
        for source in sources.values { missing.subtract(source.reportableStates) }
        missing.remove(.unknown)
        return missing
    }

    // MARK: - Input

    @discardableResult
    public mutating func record(
        _ state: AgentState,
        for sessionID: String,
        from sourceID: String,
        observedAt: Date
    ) -> IngestResult {
        guard let source = sources[sourceID] else {
            return reject("unregistered source '\(sourceID)' reported \(state.rawValue) for \(sessionID)")
        }
        guard source.reportableStates.contains(state) else {
            return reject("source '\(sourceID)' cannot report \(state.rawValue) (declares \(source.reportableStates.map(\.rawValue).sorted().joined(separator: ",")))")
        }

        var forSession = readings[sessionID] ?? [:]
        if state == .unassigned {
            // Nothing else describes this slot any more.
            forSession = [:]
        } else {
            // Evidence about a session means the slot is bound after all.
            forSession = forSession.filter { $0.value.state != .unassigned }
        }
        forSession[sourceID] = StateReading(sourceID: sourceID, state: state, observedAt: observedAt)
        readings[sessionID] = forSession
        return .accepted
    }

    /// Drop a `needsInput` reading whose *end* a source has witnessed, without that
    /// source ever gaining the vocabulary to assert `needsInput` itself.
    ///
    /// This exists because rejecting a permission prompt emits no hook event at all —
    /// witnessed in `spikes/needsinput`, both reject affordances: no `PermissionDenied`,
    /// no `Stop`, no `PostToolUseFailure`, and no `Notification` after 170 s idle. So
    /// `PermissionRequest` turns a key amber and the hook stream has nothing left to
    /// say, while the only account of the rejection is in the transcript — and
    /// `claude.transcript` must never gain `.needsInput` in `reportableStates`, because
    /// a *pending* prompt writes nothing to disk and claiming otherwise is the exact
    /// lie `reportableStates` exists to prevent.
    ///
    /// **Clearing is not reporting**, and the asymmetry is the whole point: this can
    /// only ever take amber down. It never names a replacement state, so whatever the
    /// contributing sources can legitimately report resolves normally — on the reject
    /// path the same transcript tail carries the `turn_duration` that closes the turn,
    /// so the key goes to a colour something actually witnessed. If nothing else has
    /// spoken, it goes to `.unknown`, which is the honest answer and not a guess.
    ///
    /// `observedAt` is when the evidence says the prompt ended, and only readings
    /// **older** than it are dropped. That comparison is load-bearing rather than
    /// defensive: the rejection marker stays inside the tailer's window for the next
    /// 80 records, so this is called again on every poll with the same old timestamp,
    /// and without it the next real `PermissionRequest` would be wiped the instant it
    /// arrived.
    @discardableResult
    public mutating func clearNeedsInput(
        for sessionID: String,
        from sourceID: String,
        observedAt: Date
    ) -> IngestResult {
        guard sources[sourceID] != nil else {
            return reject("unregistered source '\(sourceID)' cleared needsInput for \(sessionID)")
        }
        readings[sessionID] = readings[sessionID]?.filter { _, reading in
            reading.state != .needsInput || reading.observedAt >= observedAt
        }
        return .accepted
    }

    /// Liveness is never expired. If the `ps` join stops running, its last word
    /// stands: forgetting a `dead` would let `idle` back on screen, which is the
    /// one outcome this input exists to prevent.
    public mutating func setLiveness(_ value: Liveness, for sessionID: String) {
        liveness[sessionID] = value
    }

    /// Drop everything about a session. For the registry when a slot is rebound to
    /// a different thread — stale readings must not follow the key.
    public mutating func forget(_ sessionID: String) {
        readings[sessionID] = nil
        liveness[sessionID] = nil
    }

    // MARK: - Output

    public func resolve(_ sessionID: String, at now: Date) -> Resolution {
        let live = liveness[sessionID] ?? .unknown
        let all = readings[sessionID] ?? [:]
        let fresh = all.values.filter { reading in
            guard let source = sources[reading.sourceID] else { return false }
            return now.timeIntervalSince(reading.observedAt) <= source.stalenessThreshold
        }

        var unobservable = Set(AgentState.allCases)
        for reading in fresh {
            unobservable.subtract(sources[reading.sourceID]?.reportableStates ?? [])
        }
        unobservable.remove(.unknown)

        // Recomputed from the raw readings every time, which is the whole answer to
        // the stale-winner problem: a high-confidence source outranks a lower one
        // only while it is actually fresh. Nothing is latched, so when hooks go
        // quiet the transcript reading takes over on the next resolve, and when
        // hooks come back they win again. A cached resolved state would have frozen
        // the session on the reported value and suppressed a perfectly good
        // inferred stream indefinitely.
        // Confidence first — the documented rule. Then evidence time, then source
        // id, so two equally good readings resolve deterministically rather than by
        // dictionary iteration order.
        let winner = fresh.max { a, b in
            let ra = (sources[a.sourceID]?.confidence.rawValue ?? 0, a.observedAt, a.sourceID)
            let rb = (sources[b.sourceID]?.confidence.rawValue ?? 0, b.observedAt, b.sourceID)
            return ra < rb
        }
        guard let winner else {
            return Resolution(
                state: .unknown,
                confidence: .inferred,
                liveness: live,
                reason: all.isEmpty
                    ? "no source has reported"
                    : "every source went quiet (\(all.count) stale reading(s))",
                unobservable: unobservable
            )
        }

        var state = winner.state
        var confidence = sources[winner.sourceID]?.confidence ?? .inferred
        var reason = "\(winner.sourceID) reported \(state.rawValue)"

        if live == .dead, !Self.survivesDeath(state) {
            state = .unknown
            confidence = .inferred
            reason += ", but its process is gone"
        }

        return Resolution(
            state: state,
            confidence: confidence,
            liveness: live,
            reason: reason,
            unobservable: unobservable
        )
    }

    /// Bridge to the protocol boundary. `lastTransition` moves only on a real
    /// change, so "how long has it been like this" stays meaningful.
    public func apply(to session: AgentSession, at now: Date) -> AgentSession {
        let resolution = resolve(session.id, at: now)
        var updated = session
        if updated.state != resolution.state { updated.lastTransition = now }
        updated.state = resolution.state
        updated.confidence = resolution.confidence
        return updated
    }

    // MARK: - Rules

    /// `error` and `unassigned` remain true of a session whose process has
    /// exited; everything else is a claim about a running program.
    private static func survivesDeath(_ state: AgentState) -> Bool {
        state == .error || state == .unassigned || state == .unknown
    }

    private mutating func reject(_ message: String) -> IngestResult {
        rejections.append(message)
        if rejections.count > Self.rejectionLimit { rejections.removeFirst() }
        return .rejected(message)
    }
}

// MARK: - Self check

public extension StateEngine {
    /// Human-readable failures, empty when healthy. Wire into `SelfCheck` with:
    ///
    ///     failures += StateEngine.selfCheckFailures().map { "engine: \($0)" }
    ///
    /// Every check uses explicit dates. No wall clock touches this code, so a slow
    /// machine cannot make it flake.
    static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let hooks = StateSource.claudeHooks
        let tail = StateSource.claudeTranscript
        let binding = StateSource.appBinding
        let configured = [hooks, tail, binding]

        // 1. A source that cannot see needsInput never lets the engine assert
        //    not-needsInput. This is the one that keeps the amber key honest.
        var capped = StateEngine(sources: [tail])
        check(
            "transcript reporting needsInput must be rejected",
            capped.record(.needsInput, for: "s", from: tail.id, observedAt: t0) != .accepted
        )
        check("rejection was logged", !capped.rejections.isEmpty)
        check(
            "accepted state from a capable source",
            capped.record(.running, for: "s", from: tail.id, observedAt: t0) == .accepted
        )
        let cappedResolution = capped.resolve("s", at: t0)
        check("transcript-only resolves to running", cappedResolution.state == .running)
        check(
            "transcript-only must not claim needsInput is observable",
            !cappedResolution.needsInputObservable
        )
        check(
            "transcript-only engine reports the configuration gap",
            capped.statesNoSourceCanReport.contains(.needsInput)
        )
        check(
            "an unregistered source is rejected",
            capped.record(.idle, for: "s", from: "nobody", observedAt: t0) != .accepted
        )
        check(
            "an unregistered source cannot clear needsInput either",
            capped.clearNeedsInput(for: "s", from: "nobody", observedAt: t0) != .accepted
        )
        // Retracting somebody else's needsInput is allowed to a source that cannot
        // report it — that is the whole point — and it must not become a back door for
        // asserting one.
        check(
            "clearing must not resurrect the ability to report needsInput",
            !tail.reportableStates.contains(.needsInput)
        )
        check(
            "clearing a session nobody has reported on is harmless",
            capped.clearNeedsInput(for: "never-seen", from: tail.id, observedAt: t0) == .accepted
                && capped.resolve("never-seen", at: t0).state == .unknown
        )
        // Nothing but needsInput may be dropped: a clear that also removed the
        // transcript's own reading would leave the key grey instead of the colour the
        // same tail witnessed.
        var retract = StateEngine(sources: [hooks, tail])
        retract.record(.needsInput, for: "s", from: hooks.id, observedAt: t0)
        retract.record(.complete, for: "s", from: tail.id, observedAt: t0)
        retract.clearNeedsInput(for: "s", from: tail.id, observedAt: t0.addingTimeInterval(1))
        check("clearing left the session with no state at all", retract.resolve("s", at: t0).state == .complete)
        retract.clearNeedsInput(for: "s", from: tail.id, observedAt: t0.addingTimeInterval(2))
        check("clearing twice dropped an unrelated reading", retract.resolve("s", at: t0).state == .complete)

        // With a hook source also fresh, needsInput becomes visible again — and the
        // full configuration has no permanent blind spot.
        var full = StateEngine(sources: configured)
        full.record(.running, for: "s", from: tail.id, observedAt: t0)
        full.record(.running, for: "s", from: hooks.id, observedAt: t0)
        check("hooks make needsInput observable", full.resolve("s", at: t0).needsInputObservable)
        check("configured engine has no blind spot", StateEngine(sources: configured).statesNoSourceCanReport.isEmpty)

        // 2. Staleness drives to unknown at the threshold, and not before.
        var aging = StateEngine(sources: [tail])
        aging.record(.running, for: "s", from: tail.id, observedAt: t0)
        check(
            "fresh reading survives just under the threshold",
            aging.resolve("s", at: t0.addingTimeInterval(tail.stalenessThreshold - 1)).state == .running
        )
        check(
            "reading expires just past the threshold",
            aging.resolve("s", at: t0.addingTimeInterval(tail.stalenessThreshold + 1)).state == .unknown
        )
        check(
            "an engine nobody has spoken to resolves unknown",
            StateEngine(sources: configured).resolve("never-seen", at: t0).state == .unknown
        )

        // 3 + 4. Reported beats a concurrent inferred reading, and a stale reported
        //        source does NOT permanently suppress the inferred one.
        var contested = StateEngine(sources: [hooks, tail])
        contested.record(.needsInput, for: "s", from: hooks.id, observedAt: t0)
        contested.record(.running, for: "s", from: tail.id, observedAt: t0)
        check("reported beats inferred", contested.resolve("s", at: t0).state == .needsInput)
        check("reported wins with its own confidence", contested.resolve("s", at: t0).confidence == .reported)

        // Hooks go quiet; the transcript reading is still inside its own window.
        let afterHooksDie = t0.addingTimeInterval(hooks.stalenessThreshold + 1)
        check(
            "stale reported source does not suppress a fresh inferred one",
            contested.resolve("s", at: afterHooksDie).state == .running
        )
        check(
            "the surviving reading keeps its own confidence",
            contested.resolve("s", at: afterHooksDie).confidence == .inferred
        )
        // Hooks come back: they win again, with nothing latched either way.
        contested.record(.needsInput, for: "s", from: hooks.id, observedAt: afterHooksDie)
        check(
            "a returning reported source wins again",
            contested.resolve("s", at: afterHooksDie).state == .needsInput
        )
        // Both stale: unknown, not the last colour.
        check(
            "both sources stale resolves to unknown",
            contested.resolve("s", at: t0.addingTimeInterval(tail.stalenessThreshold + 100)).state == .unknown
        )

        // 5. A dead process never yields idle, whatever any source claims.
        for state in AgentState.allCases {
            guard let source = configured.first(where: { $0.reportableStates.contains(state) }) else { continue }
            var dead = StateEngine(sources: configured)
            dead.record(state, for: "s", from: source.id, observedAt: t0)
            dead.setLiveness(.dead, for: "s")
            let resolved = dead.resolve("s", at: t0)
            check("dead process reported \(state.rawValue) as idle", resolved.state != .idle)
            check("dead process lost its liveness", resolved.liveness == .dead)
        }

        // 6. Every state is reachable through the engine with the real source set.
        //    Iterating allCases so an eighth state cannot be added without a source
        //    that can produce it.
        for state in AgentState.allCases {
            var engine = StateEngine(sources: configured)
            guard state != .unknown else {
                check("unknown reachable", engine.resolve("s", at: t0).state == .unknown)
                continue
            }
            guard let source = configured.first(where: { $0.reportableStates.contains(state) }) else {
                failures.append("no configured source can report \(state.rawValue)")
                continue
            }
            engine.record(state, for: "s", from: source.id, observedAt: t0)
            let resolved = engine.resolve("s", at: t0)
            check("\(state.rawValue) unreachable via \(source.id) (got \(resolved.state.rawValue))", resolved.state == state)
        }

        // unassigned and a live session state are mutually exclusive in both
        // directions, or a cleared slot keeps its old colour and a rebound one
        // stays grey.
        var slot = StateEngine(sources: configured)
        slot.record(.running, for: "s", from: hooks.id, observedAt: t0)
        slot.record(.unassigned, for: "s", from: binding.id, observedAt: t0)
        check("clearing a slot drops the session reading", slot.resolve("s", at: t0).state == .unassigned)
        slot.record(.running, for: "s", from: hooks.id, observedAt: t0)
        check("rebinding a slot drops the unassigned reading", slot.resolve("s", at: t0).state == .running)

        // apply() moves lastTransition only on a real change.
        let session = AgentSession(id: "s", backendID: "mock", title: "t", state: .idle, lastTransition: t0)
        var bridge = StateEngine(sources: configured)
        bridge.record(.idle, for: "s", from: hooks.id, observedAt: t0)
        let later = t0.addingTimeInterval(5)
        check("unchanged state keeps lastTransition", bridge.apply(to: session, at: later).lastTransition == t0)
        bridge.record(.running, for: "s", from: hooks.id, observedAt: later)
        let moved = bridge.apply(to: session, at: later)
        check("changed state moves lastTransition", moved.lastTransition == later && moved.state == .running)

        return failures
    }
}
