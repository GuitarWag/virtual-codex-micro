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
    /// Demo driver, opt-in via `VCM_DEMO=1`. Kept because it is also M2's exit
    /// criterion: a non-real adapter bound alongside real ones is what proves the
    /// UI never branches on which backend it is talking to.
    private let demoBackend = MockBackend()
    private let useDemoBackend = ProcessInfo.processInfo.environment["VCM_DEMO"] != nil

    /// The real sources. Hooks are the only thing that can light the amber key;
    /// tailing is the only thing that can populate a key at launch, because hooks
    /// are edge-triggered with no snapshot. Neither is sufficient alone.
    private let hooks = ClaudeHookSource()
    private var transcripts = ClaudeTranscriptSource()

    /// cmux-hosted sessions. Preferred over the generic paths where a session is
    /// cmux's, because cmux can do what the terminal-scripting route cannot: focus
    /// a named surface, and deliver an approval to that surface rather than to
    /// whatever holds focus. Sessions it knows about are controllable, not merely
    /// observable.
    private let cmux = CmuxAdapter()
    /// Session ids cmux hosts, so routing does not have to re-derive it per action.
    private var cmuxHosted: Set<String> = []
    private var driftObserver: DriftTriggerObserver?

    /// The mock's own source. Long staleness threshold on purpose: the demo
    /// timeline pauses between beats and greying the panel mid-demo would look
    /// like a bug rather than the honest abstention it is for a real source.
    static let mockSource = StateSource.mock(id: "mock", stalenessThreshold: 3600)

    /// Colour test: when set, every slot reports this state, so the caps AND the
    /// aggregate underglow can be judged one colour at a time. The glow is
    /// most-urgent-wins, so mixed states only ever show the most urgent colour —
    /// seeing all seven means driving all six slots together.
    @Published private(set) var colorTestState: AgentState?

    /// Slot currently showing its detail popover, owned here so only one opens.
    @Published var detailSlot: Int?

    /// The state the case should glow.
    ///
    /// The selected key's state, falling back to the most recently received change
    /// when the selected slot has nothing to show. Replaces the urgency ranking for
    /// the glow specifically: ranking is right for an unattended panel, but it meant
    /// one stale `error` pinned the case red and every later change was invisible.
    var glowState: AgentState? {
        if let demoGlow { return demoGlow }
        let selected = state(at: selectedSlot)
        if selected != .unassigned { return selected }
        return latestReceivedState
    }

    /// The most recent state a source actually reported, regardless of slot.
    private(set) var latestReceivedState: AgentState?

    /// The last action's outcome, for brief on-panel feedback.
    ///
    /// Exists because a *correct* refusal was indistinguishable from a dead button.
    /// The adapter reads the surface before sending and declines when it cannot see
    /// a real prompt — which is the safe behaviour — but with the outcome going only
    /// to a log reachable through the menu bar, pressing accept with nothing pending
    /// looked exactly like a broken key. Silence is the wrong answer for a control
    /// surface: the whole product is about knowing what is going on at a glance.
    @Published private(set) var lastActionNote: String?

    private func note(_ text: String) {
        lastActionNote = text
        let token = UUID()
        feedbackToken = token
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if feedbackToken == token { lastActionNote = nil }
        }
    }

    private var feedbackToken: UUID?

    /// The slot the command cluster and the dial act on.
    ///
    /// This did not exist, and its absence was a real defect rather than an
    /// omission: `dispatch` targeted `detailSlot ?? 0` and the cluster's enabled
    /// state read slot 0, so clicking an agent key raised its terminal but never
    /// made it the command target. Pressing accept would have acted on slot 0
    /// whatever you had just clicked — on an approval dialog, the worst available
    /// class of bug. Defaults to slot 0 so the cluster is never targetless.
    @Published private(set) var selectedSlot: Int = 0

    func select(_ slot: Int) {
        guard (0 ..< PanelLayout.agentKeyCount).contains(slot) else { return }
        selectedSlot = slot
    }

    init() {
        // Every source must be registered before it can record: an unregistered
        // source's readings are rejected, which is the behaviour we want for a
        // typo'd id and the behaviour we must avoid for a real one.
        engine.register(.appBinding)
        engine.register(.claudeHooks)
        engine.register(.claudeTranscript)
        engine.register(OwnedSession.stateSource)
        // Without this every cmux reading is rejected as an unregistered source —
        // which the engine does deliberately and logs, but silently as far as the
        // panel is concerned.
        engine.register(.cmuxEvents)
        engine.register(.manualTest)
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
        capabilities: SessionCapabilities = .observed,
        glow: AgentState? = nil
    ) -> PanelCoordinator {
        let coordinator = PanelCoordinator()
        coordinator.demoStates = states
        coordinator.demoSessions = sessions
        coordinator.demoCapabilities = capabilities
        coordinator.demoGlow = glow
        return coordinator
    }

    private var known: [String: DiscoveredSession] = [:]
    private var knownPIDs: [String: Int32?] = [:]
    /// Pids learned from hook events via `CLAUDE_PID`.
    ///
    /// The argv join cannot see a bare `claude`: it looks for `--session-id` or
    /// `--resume`, and a session started as plain `claude` has neither. Observed
    /// live — an iTerm session on ttys011, plainly alive, reported by the tailer as
    /// "no live process carries this session id", so its state resolved to `unknown`
    /// and its key stayed grey while focus worked fine. A hook payload carries the
    /// pid directly, so this closes the hole for any launch style.
    private var hookPIDs: [String: Int32] = [:]
    private var demoStates: [Int: AgentState]?
    private var demoSessions: [Int: AgentSession] = [:]
    private var demoCapabilities: SessionCapabilities = .observed
    private var demoGlow: AgentState?

    func start() {
        if ProcessInfo.processInfo.environment["VCM_COLORTEST"] != nil {
            runColorTest()
            return
        }
        Task { await bootstrap() }
        driftObserver = DriftTriggerObserver { [weak self] trigger in
            self?.reconcile(trigger)
        }
    }

    /// Walk every state, all six keys together, holding each long enough to look
    /// at. Ends on `unassigned` so the resting appearance is visible too.
    private func runColorTest() {
        Task { @MainActor in
            let hold = Duration.milliseconds(2600)
            while !Task.isCancelled {
                for state in AgentState.allCases {
                    colorTestState = state
                    log.record(ActivityEntry(at: Date(), event: .note("colour test: \(state.label)")))
                    activity = log.entries(limit: 32)
                    try? await Task.sleep(for: hold)
                }
            }
        }
    }

    // MARK: - Bootstrap

    private func bootstrap() async {
        if useDemoBackend {
            await runDemo()
            return
        }
        await runLive()
    }

    private func runDemo() async {
        let discovered = ((try? await demoBackend.discoverSessions()) ?? [])
            .map { DiscoveredSession(session: $0) }
        for (slot, found) in discovered.prefix(PanelLayout.agentKeyCount).enumerated() {
            _ = registry.bind(found, to: slot, engine: &engine, at: Date())
            record(found.session.state, for: found.session.id, from: Self.mockSource)
        }
        refresh(discovered: discovered)
        for await updated in demoBackend.stateUpdates() {
            record(updated.state, for: updated.id, from: Self.mockSource)
            refresh(discovered: discovered)
        }
    }

    /// Cold start from disk, then follow both live channels.
    private func runLive() async {
        // Seed liveness from what the registry already persisted. A hook-learned pid
        // is only re-learned when the session next emits an event, and an idle
        // session emits nothing — so without this, a bare `claude` that was alive
        // when last bound reads as dead until it happens to do something. The pid is
        // still checked with `kill(pid, 0)` before use, so a stale one from a
        // previous run cannot resurrect a key.
        for binding in registry.bindings.compactMap({ $0 }) {
            if let pid = binding.pid { hookPIDs[binding.sessionID] = pid }
        }

        // Tailing first and on its own: at launch there are no hook events to
        // catch up on, so this is the only way six keys can mean anything before
        // the next transition happens.
        await pollCmux()
        applyConnectRequests()
        pollTranscripts()
        autobindFreeSlots()
        refresh(discovered: discoveredSessions)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in await self?.followHooks() }
            group.addTask { [weak self] in await self?.followTranscripts() }
            group.addTask { [weak self] in await self?.followCmux() }
            group.addTask { [weak self] in await self?.followCmuxDiscovery() }
        }
    }

    private func followHooks() async {
        for await event in hooks.events() {
            apply(event)
        }
    }

    private func followTranscripts() async {
        for await readings in ClaudeTranscriptSource.updates() {
            ingest(readings)
            autobindFreeSlots()
            refresh(discovered: discoveredSessions)
        }
    }

    /// One hook event. Everything the source decided to ignore still reaches the
    /// log, because "we received it and chose not to act" is exactly what the
    /// activity strip exists to show.
    private func apply(_ event: HookEvent) {
        if let pid = event.claudePID {
            hookPIDs[event.sessionID] = pid
            if knownPIDs[event.sessionID] == nil { knownPIDs[event.sessionID] = pid }
        }
        switch event.outcome {
        case .state(let state):
            record(state, for: event.sessionID, from: .claudeHooks)
        case .openSlot:
            pollTranscripts()
            autobindFreeSlots()
        case .closeSlot:
            if let slot = slot(for: event.sessionID) {
                registry.unbind(slot, engine: &engine)
            }
        case .ignored(let reason):
            log.record(ActivityEntry(at: Date(), slot: slot(for: event.sessionID),
                                     sessionID: event.sessionID,
                                     event: .note("\(event.name) ignored: \(reason)")))
        }
        refresh(discovered: discoveredSessions)
    }

    /// cmux's own view, which carries the session id directly: `surface.list`
    /// reports each surface's UUID beside the checkpoint id, so no pid or tty join
    /// is involved and none of that fragility applies.
    private func pollCmux() async {
        guard let found = try? await cmux.discoverSessions() else { return }
        for session in found {
            let isNew = known[session.id] == nil
            cmuxHosted.insert(session.id)
            known[session.id] = DiscoveredSession(session: session)
            // Only record a state on first sight. Discovery reports whatever cmux
            // last knew, which is older than anything the event stream has already
            // told us, and re-recording it would walk a key backwards every poll.
            if isNew { record(session.state, for: session.id, from: .cmuxEvents) }
        }
    }

    private func followCmux() async {
        for await updated in cmux.stateUpdates() {
            cmuxHosted.insert(updated.id)

            // An event carries a state and a session id, and nothing else worth
            // keeping: `stateUpdates` fills `title` with the raw id and has no
            // surface UUID, cwd or pid. So it must NOT replace a discovered record —
            // doing that degraded a session we could focus and send to into one we
            // could only colour. Merge the state in; re-discover when the id is new.
            if let existing = known[updated.id] {
                var merged = existing.session
                merged.state = updated.state
                merged.lastTransition = updated.lastTransition
                known[updated.id] = DiscoveredSession(session: merged, pid: existing.pid)
            } else {
                // A session that did not exist at launch. This is why opening a new
                // session lit no key: discovery ran once at startup and never again,
                // so a surface created afterwards was invisible — and the thin event
                // record had no pid, so the live-only bind rule rejected it too.
                await pollCmux()
            }

            record(updated.state, for: updated.id, from: .cmuxEvents)
            autobindFreeSlots()
            refresh(discovered: discoveredSessions)
        }
    }

    /// Re-discover on a timer as well as on unknown events. A surface can exist
    /// without having emitted an agent event yet — opened, not yet prompted — and
    /// that session should still take a key.
    private func followCmuxDiscovery() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(4))
            await pollCmux()
            applyConnectRequests()
            autobindFreeSlots()
            refresh(discovered: discoveredSessions)
        }
    }

    /// Honour sessions that asked to be connected from inside themselves.
    ///
    /// This is the only path where the session's identity is a fact rather than an
    /// inference, so it takes precedence: an explicit request binds even when
    /// discovery has never seen the session and cannot resolve a surface for it.
    /// It is also the only way to say WHICH key — a preference no discovery can
    /// deduce.
    private func applyConnectRequests() {
        for request in ConnectRequest.drain() {
            // Trust the request for identity, but keep whatever richer record
            // discovery may already hold: it may know a surface UUID, which is what
            // focus and send need and what the request cannot supply.
            let session = known[request.sessionID]?.session ?? AgentSession(
                id: request.sessionID,
                backendID: "claude",
                title: request.cwd.map { URL(filePath: $0).lastPathComponent } ?? "session",
                repoPath: request.cwd,
                state: .unknown,
                confidence: .inferred,
                capabilities: .observed
            )
            let discovered = DiscoveredSession(session: session, pid: request.pid)
            known[request.sessionID] = discovered

            // Precedence: the key the user named, else the key this session is
            // already on, else the first free one.
            //
            // The middle term was missing, and it made a colour test move the
            // session: `/v-micro-connect green` names no slot, so a session sitting
             // happily on key 4 was rebound to the first free key. Testing a colour
            // must not relocate anything — the panel's whole promise is that a key
            // keeps meaning the same session.
            let alreadyOn = (0 ..< PanelLayout.agentKeyCount).first {
                registry.binding(at: $0)?.sessionID == request.sessionID
            }
            let target = request.slotIndex(slotCount: PanelLayout.agentKeyCount)
                ?? alreadyOn
                ?? (0 ..< PanelLayout.agentKeyCount).first { registry.binding(at: $0) == nil }

            guard let slot = target else {
                log.record(ActivityEntry(at: Date(), sessionID: request.sessionID,
                                         event: .note("connect refused: every key is taken")))
                continue
            }
            _ = registry.bind(discovered, to: slot, engine: &engine, at: Date())
            log.record(ActivityEntry(at: Date(), slot: slot, sessionID: request.sessionID,
                                     event: .note("connected to key \(slot + 1) on request")))

            if let forced = request.forcedState {
                // Recorded through the engine like any other source, not painted onto
                // the view. That way it obeys the same arbitration and the same
                // expiry, and a forced colour cannot outlive its welcome or mask a
                // real state permanently — which a direct view override would.
                record(forced, for: request.sessionID, from: .manualTest)
                note("key \(slot + 1) forced \(forced.label)")
            } else {
                note("key \(slot + 1) connected")
            }
        }
    }

    private func pollTranscripts() {
        ingest(transcripts.poll(now: Date(), liveSessions: liveSessionMap()))
    }

    /// Liveness from both sources, argv and hooks.
    ///
    /// The tailer gates `idle`/`complete` on a session having a live process, which
    /// is right — without it, idle and crashed are the same colour. But its only
    /// evidence was argv, so a bare `claude` was indistinguishable from a dead one.
    /// A pid we learned from a hook is checked with `kill(pid, 0)` rather than
    /// trusted: the session may have exited since the event, and a stale pid would
    /// resurrect a dead key.
    private func liveSessionMap() -> [String: Int32] {
        var map = ClaudeTranscriptSource.liveSessions()
        for (id, pid) in hookPIDs where map[id] == nil {
            if PTYChild.isAlive(pid) { map[id] = pid }
        }
        return map
    }

    private func ingest(_ readings: [ClaudeTranscriptSource.Reading]) {
        for reading in readings {
            clearAmber(reading)
            record(reading.state, for: reading.sessionID, from: .claudeTranscript)
            engine.setLiveness(reading.liveness, for: reading.sessionID)
            knownPIDs[reading.sessionID] = reading.pid
            known[reading.sessionID] = DiscoveredSession(
                session: AgentSession(
                    id: reading.sessionID,
                    backendID: "claude",
                    title: Self.title(fromTranscriptPath: reading.transcriptPath),
                    repoPath: Self.repoPath(fromTranscriptPath: reading.transcriptPath),
                    state: reading.state,
                    confidence: .inferred,
                    // Observed: a session we did not spawn cannot be typed into.
                    capabilities: .observed
                ),
                pid: reading.pid
            )
        }
    }

    /// The reject path. A rejected permission prompt fires no hook at all, so the
    /// amber `PermissionRequest` left behind can only be taken down by the transcript
    /// — and the transcript is not allowed to report `needsInput`, so it retracts
    /// rather than reports. Logged when it actually changes the resolution, because a
    /// key that stops being amber for no stated reason is exactly the unfalsifiable
    /// colour change this app is built to avoid.
    private func clearAmber(_ reading: ClaudeTranscriptSource.Reading) {
        guard let cleared = reading.promptClearedAt else { return }
        let now = Date()
        let before = engine.resolve(reading.sessionID, at: now).state
        engine.clearNeedsInput(
            for: reading.sessionID,
            from: StateSource.claudeTranscript.id,
            observedAt: cleared
        )
        let after = engine.resolve(reading.sessionID, at: now).state
        guard before != after else { return }
        log.record(ActivityEntry(
            at: now,
            slot: slot(for: reading.sessionID),
            sessionID: reading.sessionID,
            event: .stateChange(
                from: before, to: after,
                source: StateSource.claudeTranscript.id,
                confidence: StateSource.claudeTranscript.confidence,
                reason: "the transcript witnessed the permission prompt being answered; a rejection fires no hook"
            )
        ))
    }

    /// Fill empty slots, preferring sessions that are actually alive.
    ///
    /// The registry's own order puts attention-worthy sessions first and then falls
    /// back to session id, which is right for "do not hide a blocked agent" but says
    /// nothing about liveness. Used raw it bound six long-dead transcripts and left
    /// all three running sessions unbound — the panel filled up with history. A dead
    /// session has no pid, so it cannot be focused and its state can only ever be
    /// `unknown`; a live one is the entire point of the panel.
    ///
    /// So: alive first, then the registry's ordering within each group, so the
    /// blocked-agent guarantee still holds among sessions of equal liveness.
    private func autobindFreeSlots() {
        let free = (0 ..< PanelLayout.agentKeyCount).filter { registry.binding(at: $0) == nil }
        guard !free.isEmpty else { return }
        // ONLY live sessions get a key. A dead transcript has no pid, cannot be
        // focused, cannot be acted on, and can only ever read `unknown` — so binding
        // one spends a slot to display nothing. An empty key is honest; a key that is
        // permanently grey is noise competing with the five that mean something.
        //
        // cmux-hosted sessions count as live even without a pid, because cmux gives
        // authoritative identity from the surface itself rather than from argv.
        let ordered = registry.unbound(from: discoveredSessions)
        var candidates = ordered.filter { $0.pid != nil || cmuxHosted.contains($0.session.id) }
        for slot in free {
            guard let next = candidates.first else { break }
            candidates.removeFirst()
            _ = registry.bind(next, to: slot, engine: &engine, at: Date())
        }
    }

    private var discoveredSessions: [DiscoveredSession] { Array(known.values) }

    /// The project slug is the cwd with "/" replaced by "-"; enough to show a
    /// recognisable name without pretending we know the repo layout.
    private static func repoPath(fromTranscriptPath path: String) -> String? {
        let slug = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
        guard !slug.isEmpty else { return nil }
        return slug.replacingOccurrences(of: "-", with: "/")
    }

    private static func title(fromTranscriptPath path: String) -> String {
        let repo = repoPath(fromTranscriptPath: path) ?? "session"
        return URL(fileURLWithPath: repo).lastPathComponent
    }

    private func record(_ state: AgentState, for sessionID: String, from source: StateSource) {
        let now = Date()
        let before = engine.resolve(sessionID, at: now).state
        guard case .accepted = engine.record(state, for: sessionID, from: source.id, observedAt: now)
        else { return }
        guard before != state else { return }
        latestReceivedState = state
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
            discovered: discoveredSessions,
            liveSessions: useDemoBackend ? nil : ClaudeTranscriptSource.liveSessions(),
            at: Date()
        )
        log.record(ActivityEntry(at: Date(), event: .note(report.summary)))
        refresh(discovered: [])
    }

    // MARK: - Views ask these

    func state(at slot: Int) -> AgentState {
        if let forced = colorTestState { return forced }
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
        guard let bound = registry.binding(at: slot) else { return nil }
        // A cmux session is controllable, not merely observable: cmux can target a
        // named surface, which was the whole objection to typing into a terminal we
        // did not spawn.
        if cmuxHosted.contains(bound.sessionID) { return CmuxAdapter.capabilities }
        return .observed
    }

    /// Capabilities of the SELECTED session, so the cluster shows what the keys
    /// would actually do to the session you picked.
    var focusedCapabilities: SessionCapabilities? {
        capabilities(at: selectedSlot)
    }

    // MARK: - Actions

    func activateAgentKey(_ slot: Int) {
        // Select first, so the command cluster retargets even when the session
        // cannot be focused — an unfocusable session is still one you may want to
        // act on, and tier 3 is common (a bare `claude` carries no session id).
        select(slot)
        if let bound = registry.binding(at: slot), cmuxHosted.contains(bound.sessionID) {
            // cmux focuses the actual surface, so this is Tier 1 rather than the
            // app-only raise the terminal-scripting path manages.
            Task {
                do { try await cmux.dispatch(.focus, to: bound.sessionID) }
                catch {
                    log.record(ActivityEntry(at: Date(), slot: slot, sessionID: bound.sessionID,
                                             event: .note("cmux focus failed: \(error)")))
                }
                refresh(discovered: discoveredSessions)
            }
            return
        }
        guard let binding = registry.binding(at: slot) else {
            log.record(ActivityEntry(at: Date(), slot: slot,
                                     event: .note("slot \(slot + 1) selected; nothing bound to focus")))
            refresh(discovered: discoveredSessions)
            return
        }
        // Focus is the one action available on a session we do not own, and it
        // reports a tier rather than a boolean — the UI must not promise more.
        guard let pid = binding.pid ?? knownPIDs[binding.sessionID] ?? nil else {
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
        let target = selectedSlot
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
                if cmuxHosted.contains(binding.sessionID) {
                    try await cmux.dispatch(command, to: binding.sessionID)
                    log.record(ActivityEntry(at: now, slot: target, sessionID: binding.sessionID,
                                             event: .action(command, .sent)))
                    note("\(slot.rawValue) sent to \(binding.title)")
                    refresh(discovered: discoveredSessions)
                    return
                }
                guard useDemoBackend else {
                    // Observed sessions cannot be typed into, and no owned session
                    // is spawned yet. Refusing loudly beats pretending: the key is
                    // already disabled for these capabilities, so reaching here at
                    // all is a bug worth seeing in the log.
                    throw MockBackendError.notPermitted(
                        command: "\(command)", sessionID: binding.sessionID
                    )
                }
                try await demoBackend.dispatch(command, to: binding.sessionID)
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
                note(Self.readable(error, slot: slot))
            }
            refresh(discovered: [])
        }
    }

    /// Turn a dispatch failure into something worth reading on a 46pt key's worth
    /// of space. A refusal is the common case and must not read as a malfunction.
    private static func readable(_ error: Error, slot: PanelLayout.CommandSlot) -> String {
        let text = "\(error)"
        if text.contains("refused") || text.contains("noPrompt") || text.contains("prompt") {
            return "nothing waiting to \(slot.rawValue)"
        }
        if text.contains("notPermitted") || text.contains("capab") {
            return "\(slot.rawValue) unavailable for this session"
        }
        return "\(slot.rawValue) failed"
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
