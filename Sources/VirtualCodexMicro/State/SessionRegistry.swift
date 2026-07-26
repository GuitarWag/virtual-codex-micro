import Foundation
import os

private let log = Logger(subsystem: "com.virtualcodexmicro.app", category: "registry")

// MARK: - Persistence

/// Where the six bindings are kept. Injected so the self check runs against
/// memory: a check that touches the real store is a check that can be broken by
/// yesterday's run.
public protocol BindingStore: Sendable {
    /// `nil` means "nothing stored yet", which is a first launch, not an error.
    func read() throws -> Data?
    func write(_ data: Data) throws
}

/// A JSON file under Application Support.
///
/// Chosen over `UserDefaults` for three reasons, in order of how much they hurt:
///
/// 1. `UserDefaults` for a bare SwiftPM executable is keyed by the process name,
///    and `Scripts/bundle.sh` wraps the same binary in an ad-hoc signed `.app`
///    with its own bundle identifier. Every binding would silently vanish the
///    first time the app is run bundled — which is the normal way to run it,
///    since Carbon hotkeys and TCC both need bundle identity. Losing key
///    identity at exactly that moment breaks the one promise this file exists to
///    keep.
/// 2. Writes here are atomic and synchronous on demand. `UserDefaults` decides
///    for itself when to flush, so a panic or a hard power loss can lose the last
///    binding, and there is no way to ask it not to.
/// 3. Six bindings in a readable file can be inspected, diffed and deleted by
///    hand when they go wrong. A corrupt plist in a defaults domain cannot.
public struct FileBindingStore: BindingStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static let `default`: FileBindingStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return FileBindingStore(url: base.appendingPathComponent("VirtualCodexMicro/bindings.json"))
    }()

    public func read() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// `.atomic` writes a temporary file and renames it, so an interrupted write
    /// leaves the previous bindings intact rather than a half-written file that
    /// would come back as an empty registry on the next launch.
    public func write(_ data: Data) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }
}

/// In-memory store for the self check, and for anything else that needs a
/// registry without a disk. Can be primed with bytes (to test a corrupt store)
/// or with a read error (to test an unreadable one).
public final class MemoryBindingStore: BindingStore, @unchecked Sendable {
    public enum Failure: Error { case unreadable }

    private let lock = NSLock()
    private var data: Data?
    private let readError: Error?

    public init(data: Data? = nil, readError: Error? = nil) {
        self.data = data
        self.readError = readError
    }

    public func read() throws -> Data? {
        if let readError { throw readError }
        return lock.withLock { data }
    }

    public func write(_ data: Data) throws {
        lock.withLock { self.data = data }
    }

    public var stored: Data? { lock.withLock { data } }
}

// MARK: - Values

/// Everything needed to recognise a session again after a restart. Metadata is
/// stored rather than re-derived because the whole point is to be able to *say*
/// what a stale slot used to hold — "slot 3 was `chase flaky test` on
/// `feat/auth` in acme-api" is a rebind offer a user can answer, and a bare uuid
/// is not.
public struct SlotBinding: Codable, Sendable, Equatable {
    public let sessionID: String
    public let backendID: String
    public var repoPath: String?
    public var branch: String?
    public var title: String
    /// From `CLAUDE_PID` at `SessionStart` where we have it. This is the only
    /// thing that separates "the same id" from "the same thread": the hook spike
    /// could not verify whether `session_id` survives `--resume` or `/clear`, so
    /// an id on its own is not evidence of continuity.
    public var pid: Int32?
    /// When this slot first came to mean this session. Deliberately not touched
    /// by a metadata refresh — "bound since Tuesday" is what makes a key feel
    /// like a key.
    public let boundAt: Date

    public init(
        sessionID: String,
        backendID: String,
        repoPath: String? = nil,
        branch: String? = nil,
        title: String = "",
        pid: Int32? = nil,
        boundAt: Date
    ) {
        self.sessionID = sessionID
        self.backendID = backendID
        self.repoPath = repoPath
        self.branch = branch
        self.title = title
        self.pid = pid
        self.boundAt = boundAt
    }

    init(_ found: DiscoveredSession, at now: Date) {
        self.init(
            sessionID: found.session.id,
            backendID: found.session.backendID,
            repoPath: found.session.repoPath,
            branch: found.session.branch,
            title: found.session.title,
            pid: found.pid,
            boundAt: now
        )
    }

    /// Titles, branches and pids move under a live session. Identity does not.
    func refreshed(from found: DiscoveredSession) -> SlotBinding {
        var copy = self
        copy.repoPath = found.session.repoPath
        copy.branch = found.session.branch
        copy.title = found.session.title
        copy.pid = found.pid ?? pid
        return copy
    }
}

/// A session an adapter is currently reporting, plus the pid the `AgentSession`
/// protocol type does not carry. The pid is not decoration: without it a
/// reconnect cannot tell a surviving session from a resumed one wearing the same
/// id.
public struct DiscoveredSession: Sendable {
    public let session: AgentSession
    public let pid: Int32?

    public init(session: AgentSession, pid: Int32? = nil) {
        self.session = session
        self.pid = pid
    }

    public var id: String { session.id }
}

/// What happened to one slot on the last reconnect. Four outcomes, because the
/// three failure modes need different words in the UI even though two of them
/// resolve to the same colour.
public enum SlotOutcome: String, Sendable {
    case empty
    /// Same id, same repo, same pid — this is the key still meaning what it meant.
    case rebound
    /// Nothing alive carries this id.
    case gone
    /// Something carries this id, but we cannot positively confirm it is the same
    /// thread. Treated exactly as harshly as `gone`, on purpose.
    case unconfirmed
}

public struct SlotStatus: Sendable, Equatable {
    public let slot: Int
    public let sessionID: String?
    public let outcome: SlotOutcome
    public let reason: String
    /// Sessions the user could rebind this slot to, best guess first. Offered,
    /// never applied.
    public let candidateSessionIDs: [String]

    public var needsRebind: Bool { outcome == .gone || outcome == .unconfirmed }
}

public struct BindResult: Sendable, Equatable {
    public let bound: Bool
    /// Set when the session already occupied another slot, which is now empty. A
    /// session is never in two slots at once.
    public let vacatedSlot: Int?
    /// Set when the target slot held a different session, which is now unbound.
    public let evictedSessionID: String?

    static let rejected = BindResult(bound: false, vacatedSlot: nil, evictedSessionID: nil)
}

// MARK: - Registry

/// Which session occupies which of the six agent keys, persisted, plus the
/// reconnect logic that decides whether a persisted binding still means what it
/// meant yesterday.
///
/// **The one rule everything else follows from: a key may only start meaning a
/// different thread because the user said so.** Not because a session with the
/// same id reappeared, not because the same repo now has a newer session, not
/// because a slot was empty and something plausible turned up. So the registry
/// never adopts, never re-points and never guesses; when it cannot confirm, it
/// marks the slot for rebind and shows `unknown` until a human answers. Muscle
/// memory is the product, and a key that quietly moved is worse than no key.
///
/// A value type, like `StateEngine`. The engine is passed `inout` rather than
/// owned, because the engine is keyed by session id and the registry by slot —
/// two different indexes over the same world, and folding one into the other
/// would put slot bookkeeping inside the arbitration rules.
public struct SessionRegistry: Sendable {
    public static let slotCount = PanelLayout.agentKeyCount

    public struct PendingRebind: Sendable, Equatable {
        public let reason: String
        public let candidateSessionIDs: [String]
    }

    private struct Slot: Sendable, Equatable {
        var binding: SlotBinding?
        /// Set when a reconnect could not confirm the binding. **Not persisted
        /// and not cleared by anything a backend says** — only by a positive
        /// re-confirmation or an explicit rebind. If a hook event could clear it,
        /// an unconfirmed session would flip back to a confident colour the
        /// moment it spoke, which is the auto-adopt this type exists to prevent.
        var pending: PendingRebind?
    }

    private let store: any BindingStore
    private var slots: [Slot]
    /// Anything that went wrong reading or writing the store, newest last,
    /// capped. Non-empty means a person should look; it never means stop.
    public private(set) var warnings: [String] = []

    private static let warningLimit = 16

    /// A malformed store is a bad launch, not a crash. Every failure path here
    /// ends with six empty slots and a logged reason.
    public init(store: any BindingStore = FileBindingStore.default) {
        self.store = store
        slots = Array(repeating: Slot(), count: Self.slotCount)

        do {
            guard let data = try store.read() else { return }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == Payload.currentVersion else {
                warn("store version \(payload.version) is not \(Payload.currentVersion); starting empty")
                return
            }
            if payload.bindings.count != Self.slotCount {
                warn("store holds \(payload.bindings.count) slots, expected \(Self.slotCount); extras dropped")
            }
            for (index, binding) in payload.bindings.prefix(Self.slotCount).enumerated() {
                slots[index].binding = binding
            }
        } catch {
            warn("store unreadable (\(error)); starting with no bindings")
        }
    }

    // MARK: - Reading

    public var bindings: [SlotBinding?] { slots.map(\.binding) }

    public func binding(at slot: Int) -> SlotBinding? {
        slots.indices.contains(slot) ? slots[slot].binding : nil
    }

    public func pendingRebind(at slot: Int) -> PendingRebind? {
        slots.indices.contains(slot) ? slots[slot].pending : nil
    }

    public var boundSessionIDs: Set<String> {
        Set(slots.compactMap { $0.binding?.sessionID })
    }

    /// What the key renders. Three cases, and the middle one is the whole task:
    /// an empty slot is `unassigned`, a slot whose binding could not be confirmed
    /// is `unknown` regardless of what any source claims, and a healthy slot is
    /// whatever the engine resolves.
    public func resolve(slot: Int, engine: StateEngine, at now: Date) -> Resolution {
        guard slots.indices.contains(slot) else {
            return Self.ownResolution(.unknown, reason: "no slot \(slot)")
        }
        guard let binding = slots[slot].binding else {
            return Self.ownResolution(.unassigned, reason: "slot \(slot) is empty")
        }
        if let pending = slots[slot].pending {
            return Self.ownResolution(.unknown, reason: "slot \(slot): \(pending.reason); rebind to continue")
        }
        return engine.resolve(binding.sessionID, at: now)
    }

    /// Sessions with no slot, attention first: `needsInput`, then `error`, then
    /// the rest, ties broken by id so the overflow list does not reshuffle
    /// between ticks. Task 029 owns the badge and the chooser; this is the
    /// ordering it must not have to invent, because the failure it prevents —
    /// a blocked agent hidden behind six calm ones — is a correctness bug.
    public func unbound(from discovered: [DiscoveredSession]) -> [DiscoveredSession] {
        let bound = boundSessionIDs
        return discovered
            .filter { !bound.contains($0.id) }
            .sorted {
                let a = (Self.attentionRank($0.session.state), $0.id)
                let b = (Self.attentionRank($1.session.state), $1.id)
                return a < b
            }
    }

    private static func attentionRank(_ state: AgentState) -> Int {
        switch state {
        case .needsInput: 0
        case .error: 1
        default: 2
        }
    }

    // MARK: - Slot assignment

    /// Binds a session to a slot.
    ///
    /// Two collisions, both decided here rather than left to the caller:
    ///
    /// - **The session already occupies another slot.** That slot is vacated: one
    ///   session, one key. Two keys for one thread would show the same colour
    ///   twice, offer two ways to approve one prompt, and make "which key is that
    ///   again" unanswerable — and it costs the user a slot they think they still
    ///   have. Reported as `vacatedSlot` so the UI can say where it moved from.
    /// - **The target slot holds someone else.** They are evicted and unbound,
    ///   reported as `evictedSessionID`. The user aimed at this key.
    @discardableResult
    public mutating func bind(
        _ found: DiscoveredSession, to slot: Int, engine: inout StateEngine, at now: Date
    ) -> BindResult {
        guard slots.indices.contains(slot) else {
            warn("bind of \(found.id) to out-of-range slot \(slot) ignored")
            return .rejected
        }

        let previousSlot = slots.firstIndex { $0.binding?.sessionID == found.id }
        var vacated: Int?
        if let previousSlot, previousSlot != slot {
            slots[previousSlot] = Slot()
            vacated = previousSlot
        }

        var evicted: String?
        if let occupant = slots[slot].binding, occupant.sessionID != found.id {
            // The outgoing occupant keeps no residue. If it is bound again later
            // its colour comes from a fresh reading, not from this morning.
            engine.forget(occupant.sessionID)
            evicted = occupant.sessionID
        }

        // A session arriving from outside the registry starts from nothing: any
        // reading left over from a previous binding is evidence about a slot that
        // no longer exists, and letting it survive is how a fresh key inherits a
        // stale colour. A session merely *moving* between slots keeps its
        // readings — it is the same thread and they are still true. A slot the
        // user is *re-confirming* after a failed reconnect needs no forget here
        // either: `reconnect` dropped those readings the moment it lost
        // confidence in the id, which is the right moment, and doing it in both
        // places would leave neither one provably load-bearing.
        if previousSlot == nil { engine.forget(found.id) }

        slots[slot] = Slot(binding: SlotBinding(found, at: now), pending: nil)
        persist()
        return BindResult(bound: true, vacatedSlot: vacated, evictedSessionID: evicted)
    }

    public mutating func unbind(_ slot: Int, engine: inout StateEngine) {
        guard slots.indices.contains(slot), let binding = slots[slot].binding else { return }
        // No `unassigned` recorded for the session: the session may well still be
        // alive and unbound, and telling the engine an overflow session is
        // "empty" would be a lie the overflow list then renders.
        engine.forget(binding.sessionID)
        slots[slot] = Slot()
        persist()
    }

    /// Swaps two slots, for dragging a key. No `forget` and no engine argument:
    /// the set of bound sessions is unchanged, so every stored reading is still
    /// about a session that is still bound, and dropping them would grey out two
    /// healthy keys for no reason.
    @discardableResult
    public mutating func move(from: Int, to: Int) -> Bool {
        guard slots.indices.contains(from), slots.indices.contains(to), from != to else { return false }
        slots.swapAt(from, to)
        persist()
        return true
    }

    public mutating func clearAll(engine: inout StateEngine) {
        for slot in slots.indices { unbind(slot, engine: &engine) }
    }

    // MARK: - Reconnect

    /// Re-examines every persisted binding against what the adapters can
    /// currently see. Call on launch, on wake and on foreground — task 028 owns
    /// when, this owns what.
    ///
    /// The four cases, each with its own behaviour:
    ///
    /// 1. **Alive and confirmed** — same id, same backend, same repo, same pid.
    ///    Metadata refreshes, the slot keeps showing it, any earlier rebind flag
    ///    clears. This is the common case and the one that has to be silent.
    /// 2. **Gone** — nothing alive carries the id. The slot keeps the binding so
    ///    we can still describe what it held, drops the engine's readings, and
    ///    shows `unknown`. Never `idle`: "finished and waiting" and "not there
    ///    any more" are different facts and the tailing spike proved we cannot
    ///    tell them apart from disk.
    /// 3. **A different session in the same repo** — the dangerous one. It is
    ///    offered as a rebind candidate and nothing else. Auto-adopting would
    ///    silently make a key mean a different thread, which is the worst
    ///    available outcome: the user would act on the new session believing it
    ///    is the old one, and approve a diff they never read.
    /// 4. **Id present but unconfirmable** — a resume or a reused id. The hook
    ///    spike reports `SessionStart.source` but never verified whether
    ///    `session_id` survives `--resume` or `/clear`, so continuity is
    ///    unverified rather than assumed: treated as `gone` with a different
    ///    sentence, and the same-id session is offered as the first rebind
    ///    candidate so confirming it is one click.
    @discardableResult
    public mutating func reconnect(
        discovered: [DiscoveredSession], engine: inout StateEngine, at now: Date
    ) -> [SlotStatus] {
        let byID = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var statuses: [SlotStatus] = []

        for index in slots.indices {
            guard let binding = slots[index].binding else {
                statuses.append(
                    SlotStatus(slot: index, sessionID: nil, outcome: .empty, reason: "empty", candidateSessionIDs: [])
                )
                continue
            }

            let found = byID[binding.sessionID]
            let doubt = found.flatMap { Self.identityDoubt(binding, $0) }

            if let found, doubt == nil {
                slots[index].binding = binding.refreshed(from: found)
                slots[index].pending = nil
                statuses.append(
                    SlotStatus(
                        slot: index, sessionID: binding.sessionID, outcome: .rebound,
                        reason: "still alive (pid \(found.pid.map(String.init) ?? "unknown"))",
                        candidateSessionIDs: []
                    )
                )
                continue
            }

            let outcome: SlotOutcome = found == nil ? .gone : .unconfirmed
            let reason = doubt ?? "no live session carries id \(binding.sessionID)"
            var candidates = Self.candidates(for: binding, in: discovered, bound: boundSessionIDs)
            // The same-id session goes first: if this is a resume, confirming it
            // is the answer the user most likely wants — but only as an answer.
            if found != nil { candidates.insert(binding.sessionID, at: 0) }

            engine.forget(binding.sessionID)
            slots[index].pending = PendingRebind(reason: reason, candidateSessionIDs: candidates)
            log.notice("slot \(index) needs rebind: \(reason, privacy: .public)")
            statuses.append(
                SlotStatus(
                    slot: index, sessionID: binding.sessionID, outcome: outcome,
                    reason: reason, candidateSessionIDs: candidates
                )
            )
        }

        persist()
        return statuses
    }

    /// `nil` means the binding is positively confirmed. Anything else is the
    /// sentence the rebind offer shows.
    ///
    /// Strict on purpose: a missing pid on either side is a doubt, not a pass.
    /// The cost of being strict is an occasional rebind prompt for a session that
    /// was fine; the cost of being lax is a key that means something else and
    /// says nothing. Since `SessionStart` must be a command hook anyway (it is
    /// the only shape that fires at all), `CLAUDE_PID` is available in the normal
    /// path, so strictness is close to free.
    ///
    /// Ceiling: pids recycle. A false confirmation needs a recycled pid *and* an
    /// identical session id on the same repo, which we accept; adding process
    /// start time would close it if it ever bites.
    static func identityDoubt(_ binding: SlotBinding, _ found: DiscoveredSession) -> String? {
        if found.session.backendID != binding.backendID {
            return "backend changed from \(binding.backendID) to \(found.session.backendID)"
        }
        if let was = binding.repoPath, let now = found.session.repoPath, was != now {
            return "repo changed from \(was) to \(now), so the id is not the same thread"
        }
        guard let recorded = binding.pid else {
            return "no pid was recorded when this slot was bound, so continuity across a resume is unverified"
        }
        guard let live = found.pid else {
            return "the session reports no pid, so continuity across a resume is unverified"
        }
        if recorded != live {
            return "pid changed from \(recorded) to \(live): the id was reused or the session was resumed"
        }
        return nil
    }

    /// Unbound sessions from the same backend, same repo first, then same branch.
    /// Same repo is a *hint* for a human, never a match.
    static func candidates(
        for binding: SlotBinding, in discovered: [DiscoveredSession], bound: Set<String>
    ) -> [String] {
        discovered
            .filter { $0.session.backendID == binding.backendID && !bound.contains($0.id) }
            .filter { $0.session.repoPath != nil && $0.session.repoPath == binding.repoPath }
            .sorted {
                let a = ($0.session.branch == binding.branch ? 0 : 1, $0.id)
                let b = ($1.session.branch == binding.branch ? 0 : 1, $1.id)
                return a < b
            }
            .map(\.id)
    }

    // MARK: - Store plumbing

    private struct Payload: Codable {
        static let currentVersion = 1
        var version: Int
        var bindings: [SlotBinding?]
    }

    private mutating func persist() {
        let payload = Payload(version: Payload.currentVersion, bindings: slots.map(\.binding))
        do {
            try store.write(JSONEncoder().encode(payload))
        } catch {
            warn("could not persist bindings (\(error)); slots are correct in memory only")
        }
    }

    private mutating func warn(_ message: String) {
        log.error("\(message, privacy: .public)")
        warnings.append(message)
        if warnings.count > Self.warningLimit { warnings.removeFirst() }
    }

    /// A resolution the registry produces itself, for slots the engine has no
    /// opinion about. Attributed to `app.binding` because that is exactly what it
    /// is, and carrying that source's blind spots means the UI's "we cannot see
    /// waiting" warning stays consistent with the engine's own — scoped to bound
    /// slots by the caller, since an empty key has nothing to be blind about.
    private static func ownResolution(_ state: AgentState, reason: String) -> Resolution {
        Resolution(
            state: state,
            confidence: StateSource.appBinding.confidence,
            liveness: .unknown,
            reason: "\(StateSource.appBinding.id): \(reason)",
            unobservable: appBindingBlindSpots
        )
    }

    private static let appBindingBlindSpots: Set<AgentState> = {
        var missing = Set(AgentState.allCases)
        missing.subtract(StateSource.appBinding.reportableStates)
        missing.remove(.unknown)
        return missing
    }()
}

// MARK: - Self check

public extension SessionRegistry {
    /// Human-readable failures, empty when healthy. Wire into `SelfCheck` with:
    ///
    ///     failures += SessionRegistry.selfCheckFailures().map { "registry: \($0)" }
    ///
    /// Injected store, injected dates. Nothing here touches a disk, a defaults
    /// domain or the wall clock, so it cannot flake and cannot be polluted by a
    /// previous run.
    static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let hooks = StateSource.claudeHooks
        let sources = [hooks, StateSource.claudeTranscript, StateSource.appBinding]

        func session(
            _ id: String, repo: String? = "~/dev/acme", branch: String? = "main",
            state: AgentState = .running, pid: Int32? = 100, backend: String = "claude"
        ) -> DiscoveredSession {
            DiscoveredSession(
                session: AgentSession(
                    id: id, backendID: backend, title: "work on \(id)",
                    repoPath: repo, branch: branch, state: state
                ),
                pid: pid
            )
        }

        // 1. Round trip: every slot survives a fresh registry over the same store.
        let store = MemoryBindingStore()
        var engine = StateEngine(sources: sources)
        var registry = SessionRegistry(store: store)
        for index in 0 ..< SessionRegistry.slotCount {
            registry.bind(session("s\(index)", pid: Int32(200 + index)), to: index, engine: &engine, at: t0)
        }
        let reloaded = SessionRegistry(store: store)
        check("round trip lost bindings", reloaded.bindings == registry.bindings)
        // Derived, not literal: slotCount tracks PanelLayout.agentKeyCount, which
        // moved from 6 to 8 when the encoder and joystick cells became keys. A
        // hardcoded 6 turned a correct widening into two check failures.
        check("round trip stored fewer than \(SessionRegistry.slotCount) slots",
              reloaded.bindings.compactMap { $0 }.count == SessionRegistry.slotCount)
        check("round trip logged a warning", reloaded.warnings.isEmpty)
        for index in 0 ..< SessionRegistry.slotCount {
            check(
                "slot \(index) came back as \(reloaded.binding(at: index)?.sessionID ?? "nil")",
                reloaded.binding(at: index)?.sessionID == "s\(index)"
            )
            check("slot \(index) lost its pid", reloaded.binding(at: index)?.pid == Int32(200 + index))
            check("slot \(index) lost its repo", reloaded.binding(at: index)?.repoPath == "~/dev/acme")
        }

        // 2. A live confirmed session stays put — the control for everything below,
        //    so "resolves to unknown" cannot pass by resolving to unknown always.
        var live = SessionRegistry(store: MemoryBindingStore())
        var liveEngine = StateEngine(sources: sources)
        let alive = session("alive", pid: 41)
        live.bind(alive, to: 0, engine: &liveEngine, at: t0)
        liveEngine.record(.running, for: "alive", from: hooks.id, observedAt: t0)
        check("a confirmed live binding does not resolve running", live.resolve(slot: 0, engine: liveEngine, at: t0).state == .running)
        let liveStatuses = live.reconnect(discovered: [alive], engine: &liveEngine, at: t0)
        check("live session did not rebind", liveStatuses[0].outcome == .rebound)
        check("live session asked for a rebind", !liveStatuses[0].needsRebind)
        check(
            "reconnect broke a healthy binding",
            live.resolve(slot: 0, engine: liveEngine, at: t0).state == .running
        )

        // 3. Session gone → unknown, NOT idle, and NOT silently cleared.
        var gone = SessionRegistry(store: MemoryBindingStore())
        var goneEngine = StateEngine(sources: sources)
        gone.bind(session("ghost", pid: 77), to: 2, engine: &goneEngine, at: t0)
        goneEngine.record(.idle, for: "ghost", from: hooks.id, observedAt: t0)
        check("bound session should read idle before it vanishes", gone.resolve(slot: 2, engine: goneEngine, at: t0).state == .idle)
        let goneStatuses = gone.reconnect(discovered: [], engine: &goneEngine, at: t0)
        check("a vanished session was not reported gone", goneStatuses[2].outcome == .gone)
        check("a vanished session did not offer rebind", goneStatuses[2].needsRebind)
        let goneResolved = gone.resolve(slot: 2, engine: goneEngine, at: t0)
        // The sharp end: without forget() the hook's idle reading is still fresh
        // at t0 and outranks anything the registry says, so this is the assertion
        // that fails if forget-on-rebind is removed.
        check("a vanished session still reads idle", goneResolved.state != .idle)
        check("a vanished session does not read unknown", goneResolved.state == .unknown)
        check("the slot was silently emptied instead of offering rebind", gone.binding(at: 2)?.sessionID == "ghost")
        check("no rebind reason recorded", gone.pendingRebind(at: 2) != nil)
        // And a later hook event must not talk the slot back into a colour.
        goneEngine.record(.running, for: "ghost", from: hooks.id, observedAt: t0.addingTimeInterval(1))
        check(
            "a hook event silently re-confirmed an unconfirmed slot",
            gone.resolve(slot: 2, engine: goneEngine, at: t0.addingTimeInterval(1)).state == .unknown
        )

        // 4. A different session in the same repo is offered, never adopted.
        var repo = SessionRegistry(store: MemoryBindingStore())
        var repoEngine = StateEngine(sources: sources)
        repo.bind(session("old", repo: "~/dev/acme", pid: 10), to: 1, engine: &repoEngine, at: t0)
        let sibling = session("new", repo: "~/dev/acme", pid: 11)
        let elsewhere = session("other-repo", repo: "~/dev/docs", pid: 12)
        let repoStatuses = repo.reconnect(discovered: [sibling, elsewhere], engine: &repoEngine, at: t0)
        check("same-repo reconnect did not report gone", repoStatuses[1].outcome == .gone)
        check("slot was re-pointed at a different session", repo.binding(at: 1)?.sessionID == "old")
        check("same-repo sibling was not offered as a candidate", repoStatuses[1].candidateSessionIDs == ["new"])
        check("slot resolves to something other than unknown", repo.resolve(slot: 1, engine: repoEngine, at: t0).state == .unknown)
        check("adopted session is missing from the unbound list", repo.unbound(from: [sibling, elsewhere]).count == 2)

        // 5. Same id, different pid: a resume we cannot confirm.
        var resumed = SessionRegistry(store: MemoryBindingStore())
        var resumedEngine = StateEngine(sources: sources)
        resumed.bind(session("same-id", pid: 500), to: 3, engine: &resumedEngine, at: t0)
        resumedEngine.record(.running, for: "same-id", from: hooks.id, observedAt: t0)
        let resumedStatuses = resumed.reconnect(discovered: [session("same-id", pid: 900)], engine: &resumedEngine, at: t0)
        check("a reused id was treated as continuous", resumedStatuses[3].outcome == .unconfirmed)
        check("a reused id did not ask for a rebind", resumedStatuses[3].needsRebind)
        check("a reused id kept its colour", resumed.resolve(slot: 3, engine: resumedEngine, at: t0).state == .unknown)
        check(
            "the same-id session was not offered first as a rebind candidate",
            resumedStatuses[3].candidateSessionIDs.first == "same-id"
        )
        // The user answers the offer by rebinding the same slot to the same id.
        // This is where a missing forget() actually bites: the slot stops being
        // flagged, so nothing masks the readings any more, and the pre-resume
        // `running` would come straight back as a confident colour describing a
        // process that no longer exists.
        resumed.bind(session("same-id", pid: 900), to: 3, engine: &resumedEngine, at: t0)
        check("an explicit rebind left the slot flagged", resumed.pendingRebind(at: 3) == nil)
        check("the confirmed binding kept the old pid", resumed.binding(at: 3)?.pid == 900)
        check(
            "confirming a resumed session inherited its pre-resume colour",
            resumed.resolve(slot: 3, engine: resumedEngine, at: t0).state == .unknown
        )
        // A missing pid on either side is a doubt, not a pass.
        check(
            "a binding with no recorded pid was confirmed anyway",
            SessionRegistry.identityDoubt(
                SlotBinding(sessionID: "x", backendID: "claude", repoPath: "~/dev/acme", pid: nil, boundAt: t0),
                session("x", pid: 5)
            ) != nil
        )
        check(
            "a session reporting no pid was confirmed anyway",
            SessionRegistry.identityDoubt(
                SlotBinding(sessionID: "x", backendID: "claude", repoPath: "~/dev/acme", pid: 5, boundAt: t0),
                session("x", pid: nil)
            ) != nil
        )
        check(
            "a matching id, repo and pid was not confirmed",
            SessionRegistry.identityDoubt(
                SlotBinding(sessionID: "x", backendID: "claude", repoPath: "~/dev/acme", pid: 5, boundAt: t0),
                session("x", pid: 5)
            ) == nil
        )

        // 6. Binding a session that already holds another slot moves it.
        var moved = SessionRegistry(store: MemoryBindingStore())
        var movedEngine = StateEngine(sources: sources)
        moved.bind(session("a", pid: 1), to: 0, engine: &movedEngine, at: t0)
        moved.bind(session("b", pid: 2), to: 4, engine: &movedEngine, at: t0)
        movedEngine.record(.running, for: "a", from: hooks.id, observedAt: t0)
        movedEngine.record(.complete, for: "b", from: hooks.id, observedAt: t0)
        let result = moved.bind(session("a", pid: 1), to: 4, engine: &movedEngine, at: t0)
        check("moving a bound session did not report the vacated slot", result.vacatedSlot == 0)
        check("moving a bound session did not report the evicted occupant", result.evictedSessionID == "b")
        check("the old slot was not vacated", moved.binding(at: 0) == nil)
        check("the session is not in its new slot", moved.binding(at: 4)?.sessionID == "a")
        check(
            "a session ended up in two slots at once",
            moved.bindings.compactMap { $0?.sessionID }.filter { $0 == "a" }.count == 1
        )
        check(
            "a moved session lost readings that are still true",
            moved.resolve(slot: 4, engine: movedEngine, at: t0).state == .running
        )
        check("the vacated slot does not read unassigned", moved.resolve(slot: 0, engine: movedEngine, at: t0).state == .unassigned)
        check("the evicted occupant kept its readings", movedEngine.resolve("b", at: t0).state == .unknown)

        // 7. Rebinding a slot must not let the newcomer inherit a colour. The
        //    leftover reading below is exactly what a previous binding would have
        //    left behind, and it is fresh, so only forget() can stop it showing.
        var rebound = SessionRegistry(store: MemoryBindingStore())
        var reboundEngine = StateEngine(sources: sources)
        reboundEngine.record(.complete, for: "fresh", from: hooks.id, observedAt: t0)
        check("fixture is wrong: leftover reading is not visible", reboundEngine.resolve("fresh", at: t0).state == .complete)
        rebound.bind(session("fresh", pid: 3), to: 5, engine: &reboundEngine, at: t0)
        check(
            "a new binding inherited a stale colour",
            rebound.resolve(slot: 5, engine: reboundEngine, at: t0).state == .unknown
        )
        // Unbinding does the same for the departing session.
        reboundEngine.record(.running, for: "fresh", from: hooks.id, observedAt: t0)
        rebound.unbind(5, engine: &reboundEngine)
        check("unbind left the slot bound", rebound.binding(at: 5) == nil)
        check("unbind left a reading behind", reboundEngine.resolve("fresh", at: t0).state == .unknown)
        check("an empty slot does not read unassigned", rebound.resolve(slot: 5, engine: reboundEngine, at: t0).state == .unassigned)

        // 8. A corrupt or unreadable store yields an empty registry, never a throw.
        for (label, badStore) in [
            ("garbage", MemoryBindingStore(data: Data("not json at all".utf8))),
            ("truncated", MemoryBindingStore(data: Data(#"{"version":1,"bindings":[{"sessionID""#.utf8))),
            ("wrong version", MemoryBindingStore(data: Data(#"{"version":99,"bindings":[]}"#.utf8))),
            ("empty file", MemoryBindingStore(data: Data())),
            ("unreadable", MemoryBindingStore(readError: MemoryBindingStore.Failure.unreadable)),
        ] {
            let broken = SessionRegistry(store: badStore)
            check("\(label) store did not yield \(SessionRegistry.slotCount) slots", broken.bindings.count == SessionRegistry.slotCount)
            check("\(label) store yielded a binding", broken.bindings.allSatisfy { $0 == nil })
            check("\(label) store logged no reason", !broken.warnings.isEmpty)
        }
        // A first launch is not a corrupt store and must not warn.
        check("first launch logged a warning", SessionRegistry(store: MemoryBindingStore()).warnings.isEmpty)
        // A corrupt store still accepts new bindings and repairs itself.
        let repairing = MemoryBindingStore(data: Data("junk".utf8))
        var repaired = SessionRegistry(store: repairing)
        var repairEngine = StateEngine(sources: sources)
        repaired.bind(session("after", pid: 8), to: 0, engine: &repairEngine, at: t0)
        check("a corrupt store was not overwritten", SessionRegistry(store: repairing).binding(at: 0)?.sessionID == "after")

        // 9. Overflow ordering: blocked and broken sessions come first.
        let overflowRegistry = SessionRegistry(store: MemoryBindingStore())
        let pool = [
            session("z-idle", state: .idle),
            session("m-error", state: .error),
            session("a-running", state: .running),
            session("y-waiting", state: .needsInput),
            session("b-error", state: .error),
        ]
        let order = overflowRegistry.unbound(from: pool).map(\.id)
        check("needsInput did not sort first (got \(order))", order.first == "y-waiting")
        check("errors did not sort ahead of calm sessions", order == ["y-waiting", "b-error", "m-error", "a-running", "z-idle"])
        // Bound sessions are not overflow.
        var partly = SessionRegistry(store: MemoryBindingStore())
        var partlyEngine = StateEngine(sources: sources)
        partly.bind(pool[3], to: 0, engine: &partlyEngine, at: t0)
        check(
            "a bound session was reported as unbound",
            !partly.unbound(from: pool).contains { $0.id == "y-waiting" }
        )
        check("unbound count wrong after binding one", partly.unbound(from: pool).count == 4)

        // 10. Out-of-range slots are refused rather than trapping.
        var edge = SessionRegistry(store: MemoryBindingStore())
        var edgeEngine = StateEngine(sources: sources)
        let pastEnd = SessionRegistry.slotCount
        check("binding to slot \(pastEnd) was accepted",
              !edge.bind(session("nope"), to: pastEnd, engine: &edgeEngine, at: t0).bound)
        check("binding to slot -1 was accepted", !edge.bind(session("nope"), to: -1, engine: &edgeEngine, at: t0).bound)
        check("out-of-range bind logged nothing", !edge.warnings.isEmpty)
        check("swap with an out-of-range slot succeeded", !edge.move(from: 0, to: 9))

        return failures
    }
}
