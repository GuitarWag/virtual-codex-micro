import AppKit
import Foundation
import os

private let log = Logger(subsystem: "com.virtualcodexmicro.app", category: "drift")

/// Re-verifies every bound session at the moments when the app can no longer
/// trust what it last saw.
///
/// **Why this is not defensive paranoia.** Three spike findings make a panel
/// left to itself go quietly wrong:
///
/// - Hooks are edge-triggered with no snapshot and no query (hooks gap G2). An
///   event that fired while we were asleep, throttled or not yet launched is
///   simply lost — there is no catch-up, no replay, nothing to ask.
/// - `SIGKILL` produces no `SessionEnd` (G3), so a session can die completely
///   silently and the last hook we hold stays "true" forever.
/// - The transcript has no session-exit record of any kind (tailing 3c), so a
///   graceful quit, a `Ctrl-C`, a crash and a session sitting at its prompt
///   leave byte-identical tails. `ps` is the only thing that separates them.
///
/// So the guard does two things and delegates every judgement it can:
///
/// 1. Re-establishes liveness through the `ps` join
///    (`ClaudeTranscriptSource.liveSessions()` — reused, not reimplemented) and
///    hands the result to `SessionRegistry.reconnect(discovered:engine:at:)`,
///    which already decides the four cases correctly including the same-repo
///    different-session trap. This type does not re-litigate any of that; it
///    supplies evidence and reports the `SlotStatus` it gets back.
/// 2. Decides whether time has passed in which state *readings* — not just
///    bindings — became unverifiable, and drops them when it has. See
///    `unverifiableAfter`.
///
/// Anything unverifiable ends up `unknown`. Not `idle`, not the last known
/// colour. That is the entire point: the plan names drift between the panel and
/// reality as risk #1, and the only honest answer to "we lost track" is to say
/// so on the key.
///
/// A value type like `StateEngine` and `SessionRegistry`, holding one piece of
/// state: when it last successfully reconciled. Whoever owns the registry owns
/// one of these.
public struct DriftGuard: Sendable {
    /// Why we are re-verifying. Carried through to the report so the log can say
    /// which moment produced a grey key, but note that the *treatment* of a
    /// trigger does not depend on the case — it depends on how much
    /// unaccounted-for time has passed. `DriftTriggerObserver` maps the real
    /// notifications onto these; the reconcile logic takes one as an injected
    /// input so it is testable with no running app.
    public enum Trigger: String, Sendable, Equatable {
        /// First reconcile of the process. Nothing is known yet, by definition.
        case launch
        /// The app came to the foreground: the user is about to read the keys.
        case activated
        /// System wake. The window in which hook events were lost.
        case wake
        /// Displays added, removed or rearranged — often the tail end of a
        /// dock/undock, and the moment a cached tty-to-window mapping stops
        /// being true (focus spike: tty numbers are recycled within minutes).
        case displayReconfigured
        /// Periodic backstop, for everything the notifications do not cover:
        /// `SIGKILL`, a session quit in another Space, a hook listener that
        /// stopped being talked to.
        case tick
    }

    /// What one reconcile did. Structured rather than logged directly, because
    /// `State/ActivityLog.swift` (task 027) is being built in parallel and this
    /// must not depend on it.
    ///
    /// One-line integration once it lands:
    ///
    ///     activityLog.record(report.summary)
    public struct Report: Sendable, Equatable {
        public let trigger: Trigger
        public let at: Date
        /// Seconds since the last successful reconcile. `nil` on the first one,
        /// which is treated as unbounded.
        public let unverifiableFor: TimeInterval?
        /// True when the gap above exceeded `unverifiableAfter` and every bound
        /// session's readings were therefore dropped.
        public let invalidatedReadings: Bool
        /// One entry per slot, straight from `SessionRegistry.reconnect`. Not
        /// re-interpreted here: `outcome` and `reason` are the registry's words.
        public let slots: [SlotStatus]

        /// Slots whose binding was positively re-confirmed: same id, same
        /// backend, same repo, same live pid.
        public var verified: [SlotStatus] { slots.filter { $0.outcome == .rebound } }
        /// Slots we could not confirm. `gone` and `unconfirmed` are different
        /// sentences and the same colour.
        public var unverified: [SlotStatus] { slots.filter(\.needsRebind) }

        public var summary: String {
            let window = unverifiableFor.map { "\(Int($0))s" } ?? "unbounded"
            var parts = [
                "\(trigger.rawValue): \(verified.count) verified",
                "\(unverified.count) unverifiable",
                "gap \(window)",
            ]
            if invalidatedReadings { parts.append("readings dropped") }
            for slot in unverified { parts.append("slot \(slot.slot) \(slot.outcome.rawValue): \(slot.reason)") }
            return parts.joined(separator: "; ")
        }
    }

    // MARK: - The threshold

    /// Unaccounted-for time after which every stored reading is discarded,
    /// whatever its own source's staleness window says.
    ///
    /// **Why a threshold at all.** A two-second app switch and an eight-hour
    /// sleep are not the same event. Staleness alone does not cover the sleep:
    /// the transcript source's window is 90s, so a 61-second lid-close leaves a
    /// pre-sleep `running` reading technically fresh, while any hook event that
    /// fired inside that minute — `PermissionRequest`, `Stop`, a crash — is gone
    /// with no way to ask for it. Freshness must not survive a sleep, because
    /// freshness measures the *evidence's* age and says nothing about whether we
    /// were listening.
    ///
    /// **Why 15s specifically.** It is `StateSource.claudeHooks`' own staleness
    /// window, and that is the meaning we want: 15s is already the point at
    /// which we declare the push channel to have gone quiet while awake (seven
    /// missed 2s ticks). A gap shorter than that is shorter than the silence we
    /// tolerate with the machine running, so it earns no extra treatment — and
    /// an over-eager guard that greys six keys on every focus change is its own
    /// bug, the kind that teaches users to ignore the colour. A gap longer than
    /// it means at least one full hook-silence window passed with no possible
    /// catch-up, which is exactly when the last colour stops being evidence.
    ///
    /// It must stay *below* the longest source window (transcript, 90s) or the
    /// rule is unreachable and a slept-through reading keeps its colour.
    /// `selfCheckFailures()` enforces that ordering rather than trusting it.
    public static let unverifiableAfter: TimeInterval = StateSource.claudeHooks.stalenessThreshold

    /// Backstop cadence. Deliberately below `unverifiableAfter`, so a machine
    /// that is merely idle never invalidates anything: a normal tick arrives
    /// inside the window it would otherwise trip.
    public static let tickInterval: TimeInterval = 10

    /// Backends the `ps` join can speak for. `liveSessions()` matches `claude`
    /// processes carrying `--session-id` in argv, so it is evidence of absence
    /// for those and evidence of nothing at all for anyone else. Without this
    /// filter the mock adapter bound alongside real sessions (the M2 exit
    /// criterion that proves the protocol boundary) would be declared gone on
    /// every single reconcile.
    public static let livenessCoveredBackendIDs: Set<String> = ["claude"]

    /// When the last reconcile completed. The only stored state, and the whole
    /// clock: see `reconcile`.
    public private(set) var lastReconcileAt: Date?

    public init(lastReconcileAt: Date? = nil) {
        self.lastReconcileAt = lastReconcileAt
    }

    // MARK: - Reconcile

    /// Re-verifies every bound slot and returns what happened.
    ///
    /// **The gap, not the notification, decides.** `NSWorkspace.didWakeNotification`
    /// carries no duration, and pairing it with `willSleep` would still miss the
    /// cases that matter just as much: App Nap throttling a background
    /// `LSUIElement` app's timers, a process suspended under a debugger, a
    /// launch after the machine was asleep for a day. Measuring elapsed wall
    /// time since the last *successful* reconcile covers all of them with one
    /// mechanism and needs no bookkeeping across a sleep — and it is what makes
    /// this function testable with a pinned clock instead of a real wake.
    ///
    /// - Parameters:
    ///   - discovered: what the adapters can currently see. Optional but worth
    ///     passing: the `ps` map alone can confirm or deny a binding, but only
    ///     real discovery can offer the *alternatives* a rebind prompt needs
    ///     (the same-repo-different-session case).
    ///   - liveSessions: `session id -> pid`. `nil` runs the real `ps` join.
    ///     Injected so the self check never spawns a process.
    public mutating func reconcile(
        trigger: Trigger,
        registry: inout SessionRegistry,
        engine: inout StateEngine,
        discovered: [DiscoveredSession] = [],
        liveSessions: [String: Int32]? = nil,
        at now: Date
    ) -> Report {
        let bindings = registry.bindings.compactMap { $0 }
        let gap = lastReconcileAt.map { now.timeIntervalSince($0) }
        // No previous reconcile means unbounded: at launch we have missed every
        // event ever, so nothing survives.
        let invalidate = gap.map { $0 > Self.unverifiableAfter } ?? true

        if invalidate {
            // The sharp end of the whole task. Every reading about a bound
            // session goes, including ones still inside their source's window,
            // because the window measures how old the evidence is and not
            // whether we were awake to receive its successor. Liveness goes with
            // it, which is the other half: `StateEngine.setLiveness` never
            // expires, so a `dead` recorded before a sleep would outlive the
            // session's own resurrection.
            for binding in bindings { engine.forget(binding.sessionID) }
        }

        // Skip `ps` when there is nothing to verify: an unbound panel should not
        // spawn a process on every app switch.
        let live = liveSessions ?? (bindings.isEmpty ? [:] : ClaudeTranscriptSource.liveSessions())
        let evidence = Self.evidence(for: bindings, discovered: discovered, live: live)
        let statuses = registry.reconnect(discovered: evidence, engine: &engine, at: now)

        // Only after `reconnect` has ruled, and only for the slots it confirmed:
        // it drops the readings of every slot it could not confirm, so setting
        // liveness first would be writing into a record about to be erased.
        //
        // Confirmed slots get `.alive` — not decoration, since that is the only
        // thing that clears a `dead` from before a crash-and-restart. A slot the
        // join could not find is left at whatever it was, never asserted
        // `.dead`: a session started as a bare `claude` with no `--session-id`
        // is invisible to `ps` by design, and a wrong `.dead` never expires. The
        // registry's pending-rebind flag is what greys such a key, and that flag
        // clears itself on the next positive confirmation.
        for status in statuses where status.outcome == .rebound {
            if let sessionID = status.sessionID { engine.setLiveness(.alive, for: sessionID) }
        }

        lastReconcileAt = now
        let report = Report(
            trigger: trigger,
            at: now,
            unverifiableFor: gap,
            invalidatedReadings: invalidate,
            slots: statuses
        )
        if !report.unverified.isEmpty || invalidate {
            log.notice("\(report.summary, privacy: .public)")
        }
        return report
    }

    /// What `reconnect` gets to judge: the adapters' view, corrected by `ps`.
    ///
    /// Three rules, in order:
    ///
    /// 1. A discovered session is passed through as-is. Its metadata is richer
    ///    than a binding's and it is the only source of rebind candidates.
    /// 2. A bound session `ps` confirms is re-stamped with the pid `ps` just
    ///    read, and synthesized from its own binding if the adapters have not
    ///    reported it yet. That second half matters more than it looks: after a
    ///    wake the transcript tailer may not have re-polled, so without it every
    ///    slot would be declared gone on every wake and the user would face six
    ///    rebind prompts after lunch. Metadata comes from the binding, so
    ///    `identityDoubt` compares the recorded pid against the live one and
    ///    nothing else moves.
    /// 3. A bound session `ps` does *not* confirm is removed from the evidence
    ///    entirely, even if an adapter reported it. `ps` is the authority on
    ///    liveness — that is the whole finding of tailing 3c — and an adapter
    ///    reading can be a cached pid for a recycled process. Removed means
    ///    `reconnect` reports `gone`, which means `unknown`.
    ///
    /// ponytail: rule 3 has a ceiling. `liveSessions()` returns an empty map both
    /// when nothing is running and when `ps` itself failed, so a transient
    /// failure greys every covered slot for one cycle. Grey is the honest
    /// direction and `reconnect` clears the flag on the next confirmation, so
    /// this self-heals within a tick. Distinguishing the two would mean parsing
    /// `ps` here, which is the reimplementation the task forbids.
    static func evidence(
        for bindings: [SlotBinding],
        discovered: [DiscoveredSession],
        live: [String: Int32]
    ) -> [DiscoveredSession] {
        var byID = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for binding in bindings {
            if let pid = live[binding.sessionID] {
                let session = byID[binding.sessionID]?.session ?? Self.session(from: binding)
                byID[binding.sessionID] = DiscoveredSession(session: session, pid: pid)
            } else if Self.livenessCoveredBackendIDs.contains(binding.backendID) {
                byID[binding.sessionID] = nil
            }
        }

        return byID.values.sorted { $0.id < $1.id }
    }

    /// A binding described as a discovery, for the confirm-or-deny path when the
    /// adapters have not spoken yet. Evidence for `reconnect` only — it never
    /// reaches the UI, so `state` and `capabilities` stay at their honest
    /// defaults (`unknown` / observed) rather than inventing either.
    private static func session(from binding: SlotBinding) -> AgentSession {
        AgentSession(
            id: binding.sessionID,
            backendID: binding.backendID,
            title: binding.title,
            repoPath: binding.repoPath,
            branch: binding.branch
        )
    }
}

// MARK: - Triggers

/// The four real triggers, mapped onto `DriftGuard.Trigger` and nothing else.
/// Kept separate from the guard so the reconcile logic stays a pure function of
/// its inputs; this class is the only part that needs a running app.
///
/// Wiring, once `main.swift` owns a guard (one line, not done here since that
/// file is out of scope for this task):
///
///     observer = DriftTriggerObserver { trigger in coordinator.reconcile(trigger) }
///
/// Note on what is deliberately *not* observed: `PanelController` already
/// listens to `NSWorkspace.didActivateApplicationNotification` for its
/// hide-when-unpinned behaviour. That is a different question ("did some other
/// app come forward") asked on a different centre, and duplicating it here would
/// mean two objects reacting to every app switch in the system. This observes
/// our own app becoming active instead, which is the moment the user is actually
/// about to read the keys.
@MainActor
public final class DriftTriggerObserver: NSObject {
    private let fire: (DriftGuard.Trigger) -> Void
    /// `nonisolated(unsafe)` for one reason: `deinit` is nonisolated and `Timer`
    /// is not `Sendable`. Invalidating a main-run-loop timer from the release
    /// that destroys its own owner is safe in practice — this object is created
    /// and released on the main thread — and the alternative is leaving a
    /// repeating timer running for the life of the process.
    private nonisolated(unsafe) var timer: Timer?

    public init(interval: TimeInterval = DriftGuard.tickInterval, fire: @escaping (DriftGuard.Trigger) -> Void) {
        self.fire = fire
        super.init()

        // The user brought the app forward, so the keys are about to be read.
        NotificationCenter.default.addObserver(
            self, selector: #selector(appActivated),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )

        // System wake. Must come from the *workspace* notification centre — this
        // name posted to `NotificationCenter.default` is a silent no-op, which is
        // the failure mode where the guard looks wired and never runs. Not
        // `screensDidWakeNotification`: that is display wake, and a display
        // waking loses no hook events.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemWoke),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        // Monitors plugged, unplugged or rearranged — usually a dock or undock,
        // and the point at which any cached tty-to-window mapping needs
        // re-validating against a live pid.
        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        // Backstop for what produces no notification at all: a `SIGKILL`ed
        // session, a quit in another Space, a hook listener nothing is talking to
        // any more. This timer is throttled under App Nap and stops across sleep,
        // which is precisely why `DriftGuard` measures the elapsed gap instead of
        // counting ticks. `.common` mode so it keeps arriving while a menu is
        // open or the panel is being dragged.
        let timer = Timer(timeInterval: interval, target: self, selector: #selector(ticked), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        fire(.launch)
    }

    @objc private func appActivated() { fire(.activated) }
    @objc private func systemWoke() { fire(.wake) }
    @objc private func displaysChanged() { fire(.displayReconfigured) }
    @objc private func ticked() { fire(.tick) }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}

// MARK: - Self check

public extension DriftGuard {
    /// Human-readable failures, empty when healthy. Wire into `SelfCheck` with:
    ///
    ///     failures += DriftGuard.selfCheckFailures().map { "drift: \($0)" }
    ///
    /// Injected clock, injected liveness map, injected trigger. No wall clock, no
    /// real notifications, no `ps`, no disk — so it cannot flake and it cannot
    /// pass by accident on a machine that happens to be running a session.
    ///
    /// The under-eager and over-eager failures are checked against each other on
    /// purpose: check 3 asserts a fresh reading survives a short app switch,
    /// which is the control that stops every "resolves to unknown" assertion
    /// above it from passing by resolving to unknown always.
    static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let hooks = StateSource.claudeHooks
        let tail = StateSource.claudeTranscript
        let sources = [hooks, tail, StateSource.appBinding]

        // 0. The threshold's two ordering invariants. Both are silent breakages:
        //    raise it above the transcript window and a slept-through colour
        //    survives; raise the tick above it and an idle machine greys itself.
        check(
            "unverifiableAfter must stay below the longest source window or a sleep cannot invalidate anything",
            unverifiableAfter < tail.stalenessThreshold
        )
        check(
            "tickInterval must stay below unverifiableAfter or the backstop invalidates on every tick",
            tickInterval < unverifiableAfter
        )

        func bound(
            _ id: String, pid: Int32? = 100, repo: String? = "~/dev/acme", backend: String = "claude"
        ) -> DiscoveredSession {
            DiscoveredSession(
                session: AgentSession(
                    id: id, backendID: backend, title: "work on \(id)", repoPath: repo, branch: "main"
                ),
                pid: pid
            )
        }

        /// A registry with one bound session in slot 0, a guard that has already
        /// reconciled at `t0`, and one fresh reading from `source` at `t0`.
        func fixture(
            _ session: DiscoveredSession, state: AgentState = .running, from source: StateSource,
            lastReconcileAt: Date? = t0
        ) -> (SessionRegistry, StateEngine, DriftGuard) {
            var engine = StateEngine(sources: sources)
            var registry = SessionRegistry(store: MemoryBindingStore())
            registry.bind(session, to: 0, engine: &engine, at: t0)
            engine.record(state, for: session.id, from: source.id, observedAt: t0)
            return (registry, engine, DriftGuard(lastReconcileAt: lastReconcileAt))
        }

        // 1. A bound session with no live pid is unknown, and never idle. `idle`
        //    is the specific lie: the transcript cannot tell a finished turn from
        //    a killed process, and `SIGKILL` sends no SessionEnd.
        var (deadRegistry, deadEngine, deadGuard) = fixture(bound("ghost", pid: 77), state: .idle, from: hooks)
        check(
            "fixture is wrong: the bound session should read idle before the guard runs",
            deadRegistry.resolve(slot: 0, engine: deadEngine, at: t0).state == .idle
        )
        let deadReport = deadGuard.reconcile(
            trigger: .tick, registry: &deadRegistry, engine: &deadEngine,
            discovered: [bound("ghost", pid: 77)], liveSessions: [:], at: t0.addingTimeInterval(5)
        )
        let deadResolved = deadRegistry.resolve(slot: 0, engine: deadEngine, at: t0.addingTimeInterval(5))
        check("a session with no live pid still reads idle", deadResolved.state != .idle)
        check("a session with no live pid does not read unknown", deadResolved.state == .unknown)
        check("an unverifiable slot was not reported", deadReport.unverified.count == 1)
        check("an unverifiable slot was reported as verified", deadReport.verified.isEmpty)
        check("the slot was silently emptied instead of kept for rebind", deadRegistry.binding(at: 0) != nil)
        check(
            "no readings should be dropped on a 5s gap",
            !deadReport.invalidatedReadings
        )

        // 2. A long sleep invalidates a reading that is still inside its own
        //    staleness window. 61s asleep against the transcript's 90s window:
        //    the reading is technically fresh, and every hook event from that
        //    minute is gone forever, so freshness alone must not survive.
        let sleep = t0.addingTimeInterval(61)
        var (sleptRegistry, sleptEngine, sleptGuard) = fixture(bound("alive", pid: 41), from: tail)
        check(
            "fixture is wrong: a 61s-old transcript reading must still be fresh, or this proves nothing",
            sleptEngine.resolve("alive", at: sleep).state == .running
        )
        let sleptReport = sleptGuard.reconcile(
            trigger: .wake, registry: &sleptRegistry, engine: &sleptEngine,
            discovered: [bound("alive", pid: 41)], liveSessions: ["alive": 41], at: sleep
        )
        check("a 61s gap did not invalidate readings", sleptReport.invalidatedReadings)
        check("the sleep window was not reported", sleptReport.unverifiableFor == 61)
        // The session is verifiably alive — so this is not the dead-process path
        // resolving to unknown for a different reason. The binding survives; only
        // the state reading is gone.
        check("a live session was not re-confirmed across the sleep", sleptReport.verified.count == 1)
        check("a live session was flagged for rebind after a sleep", sleptReport.unverified.isEmpty)
        check("a live session lost its liveness", sleptEngine.resolve("alive", at: sleep).liveness == .alive)
        check(
            "a fresh reading survived a long sleep",
            sleptRegistry.resolve(slot: 0, engine: sleptEngine, at: sleep).state == .unknown
        )

        // 3. The converse control. A short app switch must NOT grey a fresh
        //    reading: a guard that invalidates on every focus change trains the
        //    user to ignore the colour, which is its own bug.
        let blink = t0.addingTimeInterval(2)
        var (blinkRegistry, blinkEngine, blinkGuard) = fixture(bound("alive", pid: 41), from: tail)
        let blinkReport = blinkGuard.reconcile(
            trigger: .activated, registry: &blinkRegistry, engine: &blinkEngine,
            discovered: [bound("alive", pid: 41)], liveSessions: ["alive": 41], at: blink
        )
        check("a 2s app switch dropped readings", !blinkReport.invalidatedReadings)
        check("a 2s app switch lost the binding", blinkReport.verified.count == 1)
        check(
            "a 2s app switch greyed a fresh reading",
            blinkRegistry.resolve(slot: 0, engine: blinkEngine, at: blink).state == .running
        )
        // 4. And a verifiably alive session keeps its state through a reconcile
        //    it has no reason to touch — including the state a *hook* reported,
        //    which is the one the amber key depends on.
        var (amberRegistry, amberEngine, amberGuard) = fixture(bound("alive", pid: 41), state: .needsInput, from: hooks)
        _ = amberGuard.reconcile(
            trigger: .displayReconfigured, registry: &amberRegistry, engine: &amberEngine,
            discovered: [bound("alive", pid: 41)], liveSessions: ["alive": 41], at: blink
        )
        check(
            "a display change dropped a live session's needsInput",
            amberRegistry.resolve(slot: 0, engine: amberEngine, at: blink).state == .needsInput
        )

        // 5. Idempotent: running twice changes nothing the second time. Compared
        //    on the world (bindings, pending flags, resolved states) and on the
        //    statuses, not on the report — `unverifiableFor` and
        //    `invalidatedReadings` describe the gap, and the second run's gap is
        //    genuinely zero.
        var (idemRegistry, idemEngine, idemGuard) = fixture(bound("half", pid: 41), from: tail)
        idemRegistry.bind(bound("ghost", pid: 9), to: 3, engine: &idemEngine, at: t0)
        idemEngine.record(.running, for: "ghost", from: tail.id, observedAt: t0)
        let discovered = [bound("half", pid: 41), bound("ghost", pid: 9)]
        func snapshot(_ registry: SessionRegistry, _ engine: StateEngine, at when: Date) -> [String] {
            (0 ..< SessionRegistry.slotCount).map { slot in
                let resolution = registry.resolve(slot: slot, engine: engine, at: when)
                return [
                    registry.binding(at: slot)?.sessionID ?? "-",
                    registry.pendingRebind(at: slot)?.reason ?? "-",
                    resolution.state.rawValue,
                    resolution.liveness.rawValue,
                ].joined(separator: "|")
            }
        }
        let firstRun = idemGuard.reconcile(
            trigger: .wake, registry: &idemRegistry, engine: &idemEngine,
            discovered: discovered, liveSessions: ["half": 41], at: sleep
        )
        let afterFirst = snapshot(idemRegistry, idemEngine, at: sleep)
        let secondRun = idemGuard.reconcile(
            trigger: .wake, registry: &idemRegistry, engine: &idemEngine,
            discovered: discovered, liveSessions: ["half": 41], at: sleep
        )
        let afterSecond = snapshot(idemRegistry, idemEngine, at: sleep)
        check("reconcile is not idempotent: \(afterFirst) then \(afterSecond)", afterFirst == afterSecond)
        check("reconcile produced different statuses on the second run", firstRun.slots == secondRun.slots)
        check("the second run reported a gap it did not have", secondRun.unverifiableFor == 0)
        check("the second run invalidated readings on a zero gap", !secondRun.invalidatedReadings)
        // The fixture has to contain both outcomes or idempotence is trivial.
        check("idempotence fixture lost its verified slot", firstRun.verified.count == 1)
        check("idempotence fixture lost its unverifiable slot", firstRun.unverified.count == 1)

        // 6. First reconcile of a process invalidates unconditionally: at launch
        //    every event ever sent has been missed.
        var (coldRegistry, coldEngine, coldGuard) = fixture(
            bound("alive", pid: 41), from: hooks, lastReconcileAt: nil
        )
        let cold = coldGuard.reconcile(
            trigger: .launch, registry: &coldRegistry, engine: &coldEngine,
            discovered: [bound("alive", pid: 41)], liveSessions: ["alive": 41], at: t0
        )
        check("a cold start trusted a reading it never received", cold.invalidatedReadings)
        check("a cold start reported a gap", cold.unverifiableFor == nil)
        check(
            "a cold start kept a colour from before the process existed",
            coldRegistry.resolve(slot: 0, engine: coldEngine, at: t0).state == .unknown
        )

        // 7. `ps` speaks only for the backends it can see. A mock-driven slot
        //    next to real ones is an M2 exit criterion, and a Claude-only
        //    liveness map must not declare it gone.
        var mockEngine = StateEngine(sources: sources + [StateSource.mock()])
        var mockRegistry = SessionRegistry(store: MemoryBindingStore())
        let mockSession = bound("mock-1", pid: 7, repo: "~/dev/mock", backend: "mock")
        mockRegistry.bind(mockSession, to: 1, engine: &mockEngine, at: t0)
        mockEngine.record(.running, for: "mock-1", from: StateSource.mock().id, observedAt: blink)
        var mockGuard = DriftGuard(lastReconcileAt: t0)
        let mockReport = mockGuard.reconcile(
            trigger: .activated, registry: &mockRegistry, engine: &mockEngine,
            discovered: [mockSession], liveSessions: [:], at: blink
        )
        check("a mock-backed slot was declared gone by a Claude-only ps map", mockReport.unverified.isEmpty)
        check(
            "a mock-backed slot lost its state to the ps join",
            mockRegistry.resolve(slot: 1, engine: mockEngine, at: blink).state == .running
        )

        // 8. Evidence assembly, directly. A bound session `ps` confirms but no
        //    adapter has reported yet must still be confirmable — otherwise the
        //    first wake before the tailer re-polls asks for six rebinds.
        let binding = SlotBinding(
            sessionID: "quiet", backendID: "claude", repoPath: "~/dev/acme",
            branch: "main", title: "quiet one", pid: 41, boundAt: t0
        )
        let synthesized = evidence(for: [binding], discovered: [], live: ["quiet": 41])
        check("a ps-confirmed session with no adapter reading produced no evidence", synthesized.count == 1)
        check(
            "the synthesized evidence would not confirm the binding",
            synthesized.first.map { SessionRegistry.identityDoubt(binding, $0) == nil } == true
        )
        // And the adapter's own pid never outranks the one `ps` just read.
        let restamped = evidence(
            for: [binding], discovered: [bound("quiet", pid: 500)], live: ["quiet": 900]
        )
        check("the ps pid did not win over the adapter's", restamped.first?.pid == 900)
        // An unbound discovered session is passed through untouched: it is where
        // rebind candidates come from.
        let passthrough = evidence(for: [binding], discovered: [bound("other", pid: 1)], live: ["quiet": 41])
        check("an unbound discovery was dropped", passthrough.contains { $0.id == "other" })

        // 9. An empty panel is a no-op, and asks nothing of `ps`. The nil
        //    liveness map is safe here *only* because there is nothing bound —
        //    any other use of nil in this check would spawn a process.
        var emptyEngine = StateEngine(sources: sources)
        var emptyRegistry = SessionRegistry(store: MemoryBindingStore())
        var emptyGuard = DriftGuard()
        let emptyReport = emptyGuard.reconcile(
            trigger: .tick, registry: &emptyRegistry, engine: &emptyEngine, at: t0
        )
        check("an empty panel reported slots to verify", emptyReport.verified.isEmpty)
        check("an empty panel reported slots to rebind", emptyReport.unverified.isEmpty)
        check("an empty panel did not report all six slots", emptyReport.slots.count == SessionRegistry.slotCount)
        check("an empty panel produced no summary", !emptyReport.summary.isEmpty)

        return failures
    }
}
