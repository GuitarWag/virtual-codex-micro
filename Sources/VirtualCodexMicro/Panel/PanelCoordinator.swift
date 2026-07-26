import AppKit
import SwiftUI

/// Owns the state pipeline and is the only thing the views talk to.
///
/// Every piece below was built and checked in isolation; this is where they
/// become one system. That seam is where the one real bug of the project so far
/// hid — a component whose own checks all passed while the assembled panel was
/// wrong — so the wiring is deliberately thin and does no judgement of its own:
/// the engine arbitrates state, the registry owns slot identity, the drift guard
/// decides what is still trustworthy, and this type just moves values between
/// them and records what happened.
@MainActor
final class PanelCoordinator: ObservableObject {
    /// Per-slot resolved state, recomputed rather than cached — `StateEngine` is a
    /// value type precisely so there is no second copy of the truth to drift.
    @Published private(set) var resolutions: [Int: Resolution] = [:]
    @Published private(set) var unbound: [DiscoveredSession] = []
    @Published private(set) var effortStep: Int = DialScale.effort.defaultIndex
    @Published private(set) var activity: [ActivityEntry] = []

    let log = ActivityLog()
    private var engine = StateEngine()
    private var registry = SessionRegistry()
    private var drift = DriftGuard()
    private let backend = MockBackend()
    private var driftObserver: DriftTriggerObserver?

    /// The mock's own source. Long staleness threshold on purpose: the demo
    /// timeline pauses between beats and greying the panel mid-demo would look
    /// like a bug rather than the honest abstention it is for a real source.
    static let mockSource = StateSource.mock(id: "mock", stalenessThreshold: 3600)

    /// Slot currently showing its detail popover, owned here so only one opens.
    @Published var detailSlot: Int?

    init() {
        // Every source must be registered before it can record: an unregistered
        // source's readings are rejected, which is the behaviour we want for a
        // typo'd id and the behaviour we must avoid for a real one.
        engine.register(.appBinding)
        engine.register(.claudeHooks)
        engine.register(.claudeTranscript)
        engine.register(OwnedSession.stateSource)
        engine.register(Self.mockSource)

        // Strays from a previous crash, before anything else spawns.
        OwnedSession.sweepStrays()
    }

    /// A coordinator with fixed state and no backend, for the offscreen render and
    /// previews. Bypasses the engine on purpose: the render is a picture of the
    /// view layer, and driving it through arbitration would make the image depend
    /// on staleness timers and wall-clock resolution.
    static func demo(
        states: [Int: AgentState],
        sessions: [Int: AgentSession],
        capabilities: SessionCapabilities = .observed
    ) -> PanelCoordinator {
        let coordinator = PanelCoordinator()
        coordinator.demoStates = states
        coordinator.demoSessions = sessions
        coordinator.demoCapabilities = capabilities
        return coordinator
    }

    private var demoStates: [Int: AgentState]?
    private var demoSessions: [Int: AgentSession] = [:]
    private var demoCapabilities: SessionCapabilities = .observed

    func start() {
        Task { await bootstrap() }
        driftObserver = DriftTriggerObserver { [weak self] trigger in
            self?.reconcile(trigger)
        }
    }

    // MARK: - Bootstrap

    private func bootstrap() async {
        let discovered = ((try? await backend.discoverSessions()) ?? [])
            .map { DiscoveredSession(session: $0) }

        for (slot, found) in discovered.prefix(PanelLayout.agentKeyCount).enumerated() {
            _ = registry.bind(found, to: slot, engine: &engine, at: Date())
            record(found.session.state, for: found.session.id, from: Self.mockSource)
        }
        refresh(discovered: discovered)

        for await updated in backend.stateUpdates() {
            record(updated.state, for: updated.id, from: Self.mockSource)
            refresh(discovered: discovered)
        }
    }

    private func record(_ state: AgentState, for sessionID: String, from source: StateSource) {
        let now = Date()
        let before = engine.resolve(sessionID, at: now).state
        guard case .accepted = engine.record(state, for: sessionID, from: source.id, observedAt: now)
        else { return }
        guard before != state else { return }
        log.record(ActivityEntry(
            at: now,
            slot: slot(for: sessionID),
            sessionID: sessionID,
            event: .stateChange(from: before, to: state,
                                source: source.id, confidence: source.confidence, reason: "")
        ))
    }

    private func slot(for sessionID: String) -> Int? {
        (0 ..< PanelLayout.agentKeyCount).first { registry.binding(at: $0)?.sessionID == sessionID }
    }

    private func refresh(discovered: [DiscoveredSession]) {
        let now = Date()
        var next: [Int: Resolution] = [:]
        for slot in 0 ..< PanelLayout.agentKeyCount {
            next[slot] = registry.resolve(slot: slot, engine: engine, at: now)
        }
        resolutions = next
        unbound = registry.unbound(from: discovered)
        activity = log.entries(limit: 32)
    }

    // MARK: - Drift

    private func reconcile(_ trigger: DriftGuard.Trigger) {
        let report = drift.reconcile(
            trigger: trigger,
            registry: &registry,
            engine: &engine,
            discovered: [],
            liveSessions: nil,
            at: Date()
        )
        log.record(ActivityEntry(at: Date(), event: .note(report.summary)))
        refresh(discovered: [])
    }

    // MARK: - Views ask these

    func state(at slot: Int) -> AgentState {
        if let demo = demoStates { return demo[slot] ?? .unassigned }
        return resolutions[slot]?.state ?? .unassigned
    }

    func session(at slot: Int) -> AgentSession? {
        if demoStates != nil { return demoSessions[slot] }
        guard let binding = registry.binding(at: slot) else { return nil }
        return AgentSession(
            id: binding.sessionID, backendID: binding.backendID, title: binding.title,
            repoPath: binding.repoPath, branch: binding.branch,
            state: state(at: slot),
            capabilities: capabilities(at: slot) ?? .observed
        )
    }

    /// Capabilities of the bound session, or none. `nil` means nothing is bound,
    /// which the command cluster renders differently from "bound but not allowed".
    func capabilities(at slot: Int) -> SessionCapabilities? {
        if demoStates != nil { return demoSessions[slot] == nil ? nil : demoCapabilities }
        guard registry.binding(at: slot) != nil else { return nil }
        return .observed
    }

    var focusedCapabilities: SessionCapabilities? {
        detailSlot.flatMap(capabilities(at:)) ?? capabilities(at: 0)
    }

    // MARK: - Actions

    func activateAgentKey(_ slot: Int) {
        guard let binding = registry.binding(at: slot) else { return }
        // Focus is the one action available on a session we do not own, and it
        // reports a tier rather than a boolean — the UI must not promise more.
        guard let pid = binding.pid else {
            log.record(ActivityEntry(at: Date(), slot: slot, sessionID: binding.sessionID,
                                     event: .note("cannot focus: no pid recorded for this session")))
            refresh(discovered: [])
            return
        }
        Task {
            let outcome = await FocusResolver.focus(pid: pid, cachedTTY: nil)
            log.record(ActivityEntry(at: Date(), slot: slot, sessionID: binding.sessionID,
                                     event: .note("focus: \(outcome.reason)")))
            refresh(discovered: [])
        }
    }

    func dispatch(_ slot: PanelLayout.CommandSlot) {
        let target = detailSlot ?? 0
        guard let binding = registry.binding(at: target) else {
            log.record(ActivityEntry(at: Date(), event: .note(
                "\(slot.rawValue): nothing bound to act on")))
            refresh(discovered: [])
            return
        }
        guard let command = Self.command(for: slot) else {
            log.record(ActivityEntry(at: Date(), slot: target, sessionID: binding.sessionID,
                                     event: .note("\(slot.rawValue) has no binding yet")))
            refresh(discovered: [])
            return
        }

        Task {
            let now = Date()
            do {
                try await backend.dispatch(command, to: binding.sessionID)
                // `.sent`, not `.confirmed`. The adapter accepting a command is not
                // evidence the agent acted on it — only a confirming event is, and
                // that arrives separately through the hook stream.
                log.record(ActivityEntry(at: now, slot: target, sessionID: binding.sessionID,
                                         event: .action(command, .sent)))
            } catch {
                // A capability violation lands here rather than being silently
                // swallowed, which is what makes the gating verifiable end to end.
                log.record(ActivityEntry(at: now, slot: target, sessionID: binding.sessionID,
                                         event: .action(command, .failed("\(error)"))))
            }
            refresh(discovered: [])
        }
    }

    /// Slots the panel can act on today. `pushToTalk` needs a transcript before it
    /// has a payload, and the two custom slots need a keymap binding, so neither
    /// maps to a command from here — the key stays visibly disabled rather than
    /// dispatching something invented.
    private static func command(for slot: PanelLayout.CommandSlot) -> AgentCommand? {
        switch slot {
        case .accept: .approve
        case .reject: .reject
        case .newSession: .newSession
        case .pushToTalk, .custom1, .custom2: nil
        }
    }

    func setEffort(_ step: Int) { effortStep = step }
}
