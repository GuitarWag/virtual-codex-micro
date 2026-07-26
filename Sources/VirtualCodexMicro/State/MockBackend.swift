import Foundation

/// Errors the mock raises. `notPermitted` is the important one: it is what the
/// UI's capability gating is tested against, so dispatching a command a session
/// never declared must fail loudly rather than quietly do nothing.
public enum MockBackendError: Error, CustomStringConvertible {
    case unknownSession(String)
    case notPermitted(command: String, sessionID: String)

    public var description: String {
        switch self {
        case .unknownSession(let id):
            "mock: no session with id \(id)"
        case .notPermitted(let command, let sessionID):
            "mock: session \(sessionID) does not declare the capability for \(command)"
        }
    }
}

/// A fake `AgentBackend`. Two jobs:
///
/// 1. M1 — the whole panel can be built, demoed and screenshotted with no real
///    agent running anywhere.
/// 2. M2 exit criterion — this stays bound to a real slot next to live Claude
///    sessions, with deliberately *different* declared capabilities, to prove no
///    view ever branches on which backend it is talking to. If the UI starts
///    needing to know, the protocol is wrong.
///
/// So it is a permanent fixture, not scaffolding. It is also the only backend
/// that can produce every state on demand, which makes it the thing UI tests
/// point at.
public final class MockBackend: AgentBackend {
    public let id = "mock"
    public let displayName = "Mock (demo)"

    private let store: Store

    public init() {
        store = Store(sessions: Self.seedSessions)
    }

    // MARK: - AgentBackend

    public func discoverSessions() async throws -> [AgentSession] {
        await store.snapshot()
    }

    /// Each subscriber is seeded with the current state of every session, then
    /// receives the scripted timeline. One shared driver feeds all subscribers,
    /// so two views never see divergent scripts.
    public func stateUpdates() -> AsyncStream<AgentSession> {
        let store = store
        return AsyncStream { continuation in
            let token = UUID()
            continuation.onTermination = { _ in
                Task { await store.unsubscribe(token) }
            }
            Task {
                await store.subscribe(token, continuation)
                await store.startTimeline()
            }
        }
    }

    /// Applies a plausible state effect, after checking the target session
    /// actually declared the capability. Throws when it did not — an observed
    /// session cannot be approved, and pretending otherwise is the drift the
    /// plan calls risk #1.
    public func dispatch(_ command: AgentCommand, to sessionID: String) async throws {
        guard let session = await store.session(sessionID) else {
            throw MockBackendError.unknownSession(sessionID)
        }
        guard session.capabilities.contains(Self.requiredCapability(for: command)) else {
            throw MockBackendError.notPermitted(
                command: String(describing: command), sessionID: sessionID
            )
        }

        switch command {
        case .focus:
            break // raising a window changes no agent state
        case .approve:
            // Approving what the agent was blocked on puts it back to work.
            if session.state == .needsInput { await store.apply(.running, to: sessionID) }
        case .reject:
            // Declining leaves nothing pending: the turn is over either way.
            if session.state == .needsInput { await store.apply(.idle, to: sessionID) }
        case .newSession, .sendPrompt:
            await store.apply(.running, to: sessionID)
        case .setEffort:
            break // dial position is not a state change
        }
    }

    // MARK: - Developer override

    /// Force one session to one state, for screenshots and manual QA of a state
    /// the script has not reached yet. Freezes the timeline by default, because
    /// a forced state that the script overwrites three seconds later is useless
    /// for exactly the job this method exists for. `resumeTimeline()` restarts it.
    public func override(_ state: AgentState, for sessionID: String, freezeTimeline: Bool = true) async {
        if freezeTimeline { await store.stopTimeline() }
        await store.apply(state, to: sessionID)
    }

    public func resumeTimeline() async {
        await store.startTimeline()
    }

    // MARK: - Fixture data

    /// Deliberately mixed capabilities. The asymmetry is the point: with only
    /// owned sessions here, nothing would ever exercise a disabled command key.
    public static let seedSessions: [AgentSession] = [
        AgentSession(
            id: "mock-1", backendID: "mock",
            title: "refactor auth middleware",
            repoPath: "~/dev/acme-api", branch: "feat/auth-refactor",
            state: .idle, confidence: .reported, capabilities: .owned
        ),
        AgentSession(
            id: "mock-2", backendID: "mock",
            title: "chase flaky integration test",
            repoPath: "~/dev/acme-api", branch: "main",
            state: .running, confidence: .inferred, capabilities: .observed
        ),
        AgentSession(
            id: "mock-3", backendID: "mock",
            title: "migrate to strict concurrency",
            repoPath: "~/dev/virtual-codex-micro", branch: "chore/swift6",
            state: .idle, confidence: .reported, capabilities: .owned
        ),
        AgentSession(
            id: "mock-4", backendID: "mock",
            title: "draft 0.4.0 release notes",
            repoPath: "~/dev/docs-site", branch: "docs/release-notes",
            state: .idle, confidence: .inferred, capabilities: .observed
        ),
        AgentSession(
            id: "mock-5", backendID: "mock",
            title: "bisect render perf regression",
            repoPath: "~/dev/render-core", branch: "perf/bisect",
            state: .running, confidence: .inferred, capabilities: .observed
        ),
        AgentSession(
            id: "mock-6", backendID: "mock",
            title: "scratch: tidy Package.swift",
            repoPath: "~/dev/virtual-codex-micro", branch: "main",
            state: .running, confidence: .reported, capabilities: .owned
        ),
    ]

    public struct Step: Sendable {
        public let after: Duration
        public let sessionID: String
        public let state: AgentState
    }

    /// Paced for a human watching, not a strobe: roughly three seconds a beat,
    /// about half a minute a lap, then back to the seed states and round again.
    /// Between the seed states and these steps every `AgentState` case appears —
    /// `selfCheckFailures()` enforces that against `AgentState.allCases`, so a
    /// seventh state added later cannot be silently skipped here.
    public static let timeline: [Step] = [
        .init(after: .seconds(2), sessionID: "mock-1", state: .running),
        .init(after: .seconds(3), sessionID: "mock-3", state: .running),
        // The blocked case the whole panel exists for.
        .init(after: .seconds(3), sessionID: "mock-1", state: .needsInput),
        // A state source going quiet — bound slot, no idea what it is doing.
        .init(after: .seconds(3), sessionID: "mock-5", state: .unknown),
        .init(after: .seconds(3), sessionID: "mock-1", state: .running),
        .init(after: .seconds(3), sessionID: "mock-3", state: .error),
        .init(after: .seconds(3), sessionID: "mock-1", state: .complete),
        .init(after: .seconds(3), sessionID: "mock-6", state: .complete),
        .init(after: .seconds(3), sessionID: "mock-3", state: .idle),
        // Session ended and the slot cleared: unassigned, not "done".
        .init(after: .seconds(3), sessionID: "mock-6", state: .unassigned),
        // Source came back.
        .init(after: .seconds(3), sessionID: "mock-5", state: .running),
        .init(after: .seconds(4), sessionID: "mock-1", state: .idle),
    ]

    private static func requiredCapability(for command: AgentCommand) -> SessionCapabilities {
        switch command {
        case .focus: .focus
        case .approve: .approve
        case .reject: .reject
        // Both need stdin, which is the same thing `sendPrompt` means here.
        case .newSession, .sendPrompt: .sendPrompt
        case .setEffort: .setEffort
        }
    }

    // MARK: - Self check

    /// Human-readable failures, empty when healthy. Wired into `SelfCheck` by
    /// the caller.
    public static func selfCheckFailures() -> [String] {
        var failures: [String] = []

        let ids = Set(seedSessions.map(\.id))
        for step in timeline where !ids.contains(step.sessionID) {
            failures.append("timeline step targets unknown session \(step.sessionID)")
        }

        // Iterate allCases so a future state fails loudly instead of quietly
        // never appearing in a demo.
        let visited = Set(seedSessions.map(\.state)).union(timeline.map(\.state))
        for state in AgentState.allCases where !visited.contains(state) {
            failures.append("timeline never visits AgentState.\(state.rawValue)")
        }

        guard let owned = seedSessions.first(where: { $0.capabilities == .owned }),
              let observed = seedSessions.first(where: { $0.capabilities == .observed })
        else {
            return failures + ["fixture must contain both an owned and an observed session"]
        }

        // Exercise the real dispatch path, not a copy of its rule.
        let backend = MockBackend()
        if dispatchError(backend, .approve, observed.id) == nil {
            failures.append("approve on an observed session did not throw")
        }
        if let error = dispatchError(backend, .focus, observed.id) {
            failures.append("focus on an observed session threw: \(error)")
        }
        if let error = dispatchError(backend, .approve, owned.id) {
            failures.append("approve on an owned session threw: \(error)")
        }
        if dispatchError(backend, .approve, "no-such-session") == nil {
            failures.append("dispatch to an unknown session did not throw")
        }

        return failures
    }

    /// `@unchecked Sendable` is load-bearing and safe for one specific reason:
    /// the semaphore orders the single write (before `signal`) strictly before
    /// the single read (after `wait`), so the two accesses never overlap and
    /// there is nothing for a lock to protect.
    private final class Box: @unchecked Sendable {
        var error: Error?
    }

    /// Bridges one async dispatch into the synchronous self-check, which runs on
    /// the main thread before the app loop starts. Nothing here is main-actor
    /// isolated, so blocking cannot deadlock the actor doing the work.
    private static func dispatchError(
        _ backend: MockBackend, _ command: AgentCommand, _ sessionID: String
    ) -> Error? {
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { try await backend.dispatch(command, to: sessionID) } catch { box.error = error }
            semaphore.signal()
        }
        semaphore.wait()
        return box.error
    }
}

/// All mutable state lives here so `MockBackend` itself holds nothing but
/// immutable values and satisfies `Sendable` without an escape hatch.
private actor Store {
    private var sessions: [String: AgentSession]
    private let order: [String]
    private var subscribers: [UUID: AsyncStream<AgentSession>.Continuation] = [:]
    private var timeline: Task<Void, Never>?

    init(sessions: [AgentSession]) {
        order = sessions.map(\.id)
        self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
    }

    func snapshot() -> [AgentSession] {
        order.compactMap { sessions[$0] }
    }

    func session(_ id: String) -> AgentSession? {
        sessions[id]
    }

    func subscribe(_ token: UUID, _ continuation: AsyncStream<AgentSession>.Continuation) {
        subscribers[token] = continuation
        for session in snapshot() { continuation.yield(session) }
    }

    func unsubscribe(_ token: UUID) {
        subscribers[token] = nil
        // Nobody watching, nothing to drive.
        if subscribers.isEmpty { stopTimeline() }
    }

    func apply(_ state: AgentState, to id: String) {
        guard var session = sessions[id], session.state != state else { return }
        session.state = state
        // A source that went quiet cannot also be trusted.
        session.confidence = state == .unknown ? .inferred : session.confidence
        session.lastTransition = Date()
        sessions[id] = session
        for continuation in subscribers.values { continuation.yield(session) }
    }

    private func reseed() {
        for seed in MockBackend.seedSessions {
            apply(seed.state, to: seed.id)
        }
    }

    func startTimeline() {
        guard timeline == nil else { return }
        timeline = Task { [weak self] in
            while !Task.isCancelled {
                for step in MockBackend.timeline {
                    do { try await Task.sleep(for: step.after) } catch { return }
                    await self?.apply(step.state, to: step.sessionID)
                }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await self?.reseed()
            }
        }
    }

    func stopTimeline() {
        timeline?.cancel()
        timeline = nil
    }
}
