import Foundation

// MARK: - Why this file exists at all

/// Control for sessions hosted in cmux.app.
///
/// **This overturns `spikes/focus/FINDINGS.md`.** That spike judged cmux Tier 2 —
/// app raised, tab not targetable, never typed into — because cmux's *AppleScript*
/// dictionary exposes a terminal panel's id, title and working directory and
/// nothing else: no tty, no pid, so there was nothing to match a session against
/// and no safe way to aim a keystroke. Every word of that is still true of the
/// AppleScript surface. It is simply not the only surface. cmux ships a Unix-socket
/// control CLI, and the CLI has all three of the missing pieces:
///
/// 1. **Identity.** `rpc surface.list` returns, per surface, a stable UUID *and*
///    `resume_binding.checkpoint_id`, which is the Claude session id itself. So a
///    session joins to a surface directly, with no pid and no tty in the path.
/// 2. **State.** `cmux events` is a sequenced, replayable stream of the agent hooks
///    cmux already receives. `--after <seq>` replays what was missed, which is the
///    one thing our own hook install structurally cannot do (gap G2: hooks are
///    edge-triggered with no snapshot and no query).
/// 3. **Control.** `send-key --surface <ref-or-uuid> <key>` delivers a keystroke to
///    a **named surface**, not to whatever holds focus. That was the entire safety
///    objection to injecting into a session we did not spawn, and it is gone.
///    `read-screen --surface <…>` reads the same surface back, so an injection can
///    be checked before *and* after.
///
/// Measured against cmux 0.64.19 on 2026-07-26, against the four live sessions on
/// this machine plus a throwaway workspace created for the control tests. Anything
/// below marked "measured" was observed; anything marked "unverified" was not, and
/// is handled as unknown rather than assumed.
///
/// # What cmux's event stream can and cannot see
///
/// cmux forwards a *subset* of Claude's hooks and **redacts part of every payload**.
/// Measured over a full turn including a real permission prompt:
///
/// | forwarded | not forwarded |
/// |---|---|
/// | `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `Stop`, `SubagentStop`, `Notification` | `PostToolUse`, `PostToolUseFailure`, `StopFailure`, `SessionStart`, `SessionEnd`, `PermissionDenied` |
///
/// and three fields that other parts of this app rely on are absent:
///
/// - **`tool_input` and `permission_suggestions` are stripped** (`redacted_fields:
///   ["tool_input","context"]`, `tool_input: null`, and no `permission_suggestions`
///   key at all). So task 044's payload tripwire — refuse to type unless the
///   suggestions array is the shape approve was measured against — **cannot run on
///   this stream**. `read-screen` is the only evidence of what a prompt is asking,
///   which is why the pre-read below is a hard gate and not a courtesy.
/// - **`notification_type` is absent**, so `Notification` cannot be narrowed to
///   `idle_prompt`. Eleven types share that channel including login toasts, so it
///   is ignored outright and `.idle` is declared unobservable.
/// - **`agent_id` is absent**, so the G4 subagent filter has nothing to match.
///   `SubagentStop` is still filtered by *name*, but a subagent's `Stop` is
///   indistinguishable from the main thread's. See `StateSource.cmuxEvents`.
///
/// # Safety posture
///
/// Every command this file issues is one of: read-only (`top`, `rpc surface.list`,
/// `read-screen`, `identify`, `events`), a focus change (`select-workspace`,
/// `rpc surface.focus`), or a single keystroke to one explicitly named surface
/// (`send-key`). It never runs `hooks setup`, never writes cmux config, and never
/// sends anything without a pre-read that proves a prompt is on that exact surface.
public final class CmuxAdapter: AgentBackend {
    public let id = "cmux"
    public let displayName = "cmux"

    private let cli: CmuxCLI
    private let stream: EventStream

    public init(cli: CmuxCLI = .live) {
        self.cli = cli
        stream = EventStream(cli: cli)
    }

    /// What a cmux-hosted session may be asked to do.
    ///
    /// Richer than `.observed` and deliberately short of `.owned`:
    ///
    /// - **`.focus`** — Tier 1, not Tier 2. Verified both directions on a throwaway
    ///   workspace: `select-workspace` plus `rpc surface.focus` put an exact,
    ///   named surface in front, read back through `identify`.
    /// - **`.approve` / `.reject`** — the keystroke goes to a named surface, so the
    ///   focus race that made this unsafe for other emulators does not exist here.
    ///   Verified end to end: a real `Bash` permission prompt approved with `enter`
    ///   (the tool then ran) and a second one rejected with `escape` (the transcript
    ///   confirms the rejection).
    /// - **not `.sendPrompt`** — `send <text>` demonstrably works; this adapter drove
    ///   a whole `claude` session with it. It is withheld because there is no
    ///   *verification rule* for it. Approve has one — a prompt is either on screen
    ///   or it is not — whereas typing a prompt means writing into an input line the
    ///   user may be typing into at the same moment, and "the input line is empty"
    ///   is not readable: Claude Code renders a dimmed suggested follow-up in that
    ///   line, so `❯ cat note.txt again` appears on a screen where nothing was
    ///   typed. Interleaving with a human's keystrokes is not a risk worth taking
    ///   for a convenience.
    /// - **not `.setEffort`** — same gap, worse. `/effort` opens a menu, and no
    ///   marker was measured that proves the menu is up rather than the keystroke
    ///   landing in a prompt.
    public static let capabilities: SessionCapabilities = [.focus, .approve, .reject]

    // MARK: - Discovery

    /// One agent session hosted in cmux, and every identifier needed to act on it.
    public struct Session: Sendable, Equatable {
        /// `resume_binding.checkpoint_id`. The Claude session id, already stripped
        /// of any prefix, so it joins directly to `ClaudeHookSource` and
        /// `ClaudeTranscriptSource` readings for the same session.
        public let claudeSessionID: String
        /// **The send and read target.** A UUID rather than a `surface:N` ref on
        /// purpose: refs are positional and recycle as surfaces close, which is the
        /// same trap as a reused tty — the focus spike watched a cached tty raise a
        /// stranger's window. `send-key`, `read-screen` and `rpc surface.focus` all
        /// accept the UUID (verified), so no ref is ever cached for an action.
        public let surfaceUUID: String
        /// For display and diagnostics only. Never the target of an action.
        public let surfaceRef: String
        public let workspaceUUID: String
        public let workspaceRef: String
        public let title: String
        public let cwd: String?
        /// From the `top` tag join. `nil` when that join was ambiguous — see
        /// `CmuxTopSnapshot.join(agentPID:)`. Feeds liveness and the app raise, and
        /// **never** the send target, so an ambiguous pid cannot misaim a keystroke.
        public let pid: Int32?

        public var agentSession: AgentSession {
            AgentSession(
                id: claudeSessionID,
                backendID: "cmux",
                title: title,
                repoPath: cwd,
                capabilities: CmuxAdapter.capabilities
            )
        }
    }

    /// Three read-only calls: one `top` for the pid join, one `rpc surface.list` per
    /// workspace that actually carries an agent tag.
    ///
    /// Scoping the per-workspace calls to tagged workspaces is not an optimisation,
    /// it is the definition: a workspace with no agent tag hosts no agent session,
    /// so there is nothing to ask about.
    public func discover() -> [Session] { Self.discover(cli: cli) }

    static func discover(
        cli: CmuxCLI,
        sessionIDForWorkspace: [String: String] = [:],
        sessionIDForPID: [Int32: String] = [:]
    ) -> [Session] {
        let top = CmuxTopSnapshot.parse(tsv: cli.text(["top", "--processes", "--all", "--format", "tsv"]))
        var sessions: [Session] = []
        for tag in top.agentTags {
            let listed = CmuxSurfaceInfo.parse(
                json: cli.text(["rpc", "surface.list", #"{"workspace_id":"\#(tag.workspaceUUID)"}"#])
            )
            for surface in listed {
                let pidForSurface = tag.pids.first { top.join(agentPID: $0).resolvedRef == surface.ref }

                // `hostsClaude` reads `resume_binding.kind`, and a surface that has
                // never been resumed has no resume_binding AT ALL — so this gate
                // rejected every new session before any identification was attempted.
                // That, not the checkpoint id, is why a new session lit no key.
                //
                // A claude pid resolving to this surface is equally good evidence that
                // it hosts a claude session, and it is available from the moment the
                // process exists.
                guard surface.hostsClaude || pidForSurface != nil else { continue }
                // `checkpoint_id` is a RESUME binding, and that is the whole trap: it
                // exists only once a session has been checkpointed, so a session the
                // user has just opened has none. Discovery keyed solely on it, which
                // meant every resumed session bound and every NEW one was invisible —
                // observed live with two "✳ Claude Code" surfaces reporting
                // checkpoint=NONE while four resumed siblings bound fine.
                //
                // The fallback is the event stream, which names the session id and its
                // workspace from the first event a new session emits. The caller
                // supplies that mapping; here it just fills the gap.
                let pid = pidForSurface

                // Three sources, in descending authority:
                //
                // 1. `checkpoint_id` — exact, but only exists once a session has been
                //    checkpointed, so a session just opened has none.
                // 2. The event stream, learned per workspace — but a session that has
                //    not run a turn yet has emitted nothing to learn from.
                // 3. The process's own argv.
                //
                // The third is what makes a brand-new session visible, and the split
                // is measured: cmux launches a NEW session with `--session-id <uuid>`
                // and a RESUMED one with `--resume <uuid>`. Keying only on the resume
                // checkpoint bound every resumed session and left every new one
                // invisible — two live sessions on this machine, both reporting
                // checkpoint=NONE and no events, while carrying their id in argv the
                // whole time.
                let resolved = surface.claudeSessionID.flatMap { id in
                    id.isEmpty ? nil : Self.stripSessionPrefix(id)
                }
                    ?? sessionIDForWorkspace[tag.workspaceUUID]
                    ?? pid.flatMap { sessionIDForPID[$0] }

                guard let sessionID = resolved, !sessionID.isEmpty else { continue }
                sessions.append(Session(
                    claudeSessionID: sessionID,
                    surfaceUUID: surface.uuid,
                    surfaceRef: surface.ref,
                    workspaceUUID: tag.workspaceUUID,
                    workspaceRef: tag.workspaceRef,
                    title: surface.title,
                    cwd: surface.cwd,
                    pid: pid
                ))
            }
        }
        return sessions
    }

    /// Session ids learned from the event stream, keyed by workspace, so discovery
    /// can identify a session that has no resume checkpoint yet.
    private let learned = LearnedSessions()

    actor LearnedSessions {
        private var byWorkspace: [String: String] = [:]
        func note(sessionID: String, workspaceUUID: String) { byWorkspace[workspaceUUID] = sessionID }
        func snapshot() -> [String: String] { byWorkspace }
    }

    public func discoverSessions() async throws -> [AgentSession] {
        let hints = await learned.snapshot()
        // Invert the argv join the transcript source already performs, rather than
        // re-parsing `ps` here. It validates that the argument is a real UUID, which
        // matters because `-r` also accepts a fuzzy search string.
        let byPID = Dictionary(
            ClaudeTranscriptSource.liveSessions().map { ($0.value, $0.key) },
            uniquingKeysWith: { first, _ in first }
        )
        let sessions = await Task.detached(priority: .utility) { [cli] in
            CmuxAdapter.discover(cli: cli, sessionIDForWorkspace: hints, sessionIDForPID: byPID)
        }.value
        return sessions.map(\.agentSession)
    }

    /// cmux prefixes the agent name onto the session id in its event payloads
    /// (`claude-<uuid>`). Every other source in this app keys on the bare uuid, so
    /// the prefix comes off at the boundary and nowhere else. Applied to
    /// `checkpoint_id` too, which was measured *without* a prefix — stripping is
    /// idempotent, and having one rule beats two.
    static func stripSessionPrefix(_ id: String) -> String {
        for agent in ["claude-", "codex-", "opencode-"] where id.hasPrefix(agent) {
            return String(id.dropFirst(agent.count))
        }
        return id
    }

    // MARK: - State stream

    /// Decoded agent events, oldest first, reconnecting on its own.
    ///
    /// Every event is yielded, including the ones whose outcome is `.ignored` — the
    /// activity strip exists to show what arrived and was deliberately not acted on,
    /// and on this stream that is most of the traffic.
    /// Same shape as `ClaudeHookSource.events()`: the stream is built here and the
    /// actor is only told about the continuation. Reading starts on the first
    /// subscribe and the child process is torn down when the last one goes away.
    public func events() -> AsyncStream<CmuxEvent> {
        let stream = self.stream
        return AsyncStream { continuation in
            let token = UUID()
            continuation.onTermination = { _ in
                Task { await stream.unsubscribe(token) }
            }
            Task { await stream.add(token, continuation) }
        }
    }

    public func stateUpdates() -> AsyncStream<AgentSession> {
        let events = self.events()
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    // Learn the workspace↔session pairing from ANY event, not only
                    // ones that carry a state: SessionStart is what a brand-new
                    // session emits first, and it is exactly the session discovery
                    // cannot otherwise identify.
                    if let id = event.sessionID, let workspace = event.workspaceUUID {
                        await learned.note(
                            sessionID: CmuxAdapter.stripSessionPrefix(id),
                            workspaceUUID: workspace
                        )
                    }
                    guard let state = event.outcome.state, let id = event.sessionID else { continue }
                    continuation.yield(AgentSession(
                        id: id,
                        backendID: "cmux",
                        title: id,
                        state: state,
                        confidence: StateSource.cmuxEvents.confidence,
                        capabilities: Self.capabilities,
                        lastTransition: event.observedAt
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func stop() async { await stream.stop() }

    /// Re-affirm — or retract — a standing amber, from the screen.
    ///
    /// This is the capability the needsinput spike said no hook stream has. A
    /// rejected prompt fires **no** event (witnessed there across both reject
    /// affordances, and re-witnessed here: `PermissionRequest` never receives a
    /// `completed` phase, before or after being answered), so a `needsInput` reading
    /// would either go stale to `unknown` while the prompt is genuinely still open,
    /// or sit amber forever after it closed. Both are drift.
    ///
    /// `read-screen` settles it with evidence rather than a timer. Call it on the
    /// tick the liveness join already runs, for amber sessions only:
    ///
    /// - `.prompt` — re-record `needsInput` with a fresh `observedAt`.
    /// - `.noPrompt` — `StateEngine.clearNeedsInput(observedAt: now)`. Retracting,
    ///   not reporting: the screen witnessed the prompt *ending*, which is a
    ///   different claim from knowing what replaced it.
    /// - `.unreadable` — do nothing. Silence is not evidence.
    ///
    // ponytail: the loop lives in the caller because PanelCoordinator already owns a
    // 2s tick. One more polling actor here would be a second clock to keep in step.
    public func screen(surfaceUUID: String, lines: Int = 40) -> CmuxScreen {
        let response = cli.run(["read-screen", "--surface", surfaceUUID, "--lines", String(lines)])
        guard !response.failed else { return .unreadable(response.problem) }
        return CmuxScreen.parse(response.out)
    }

    // MARK: - Focus

    /// Raise cmux, select the workspace, select the surface, then **read back what is
    /// actually in front**.
    ///
    /// Reported through `FocusTier`/`FocusOutcome` rather than a vocabulary of its
    /// own, so the UI keeps one sentence per tier for every host. cmux now earns
    /// `.windowAndTab` here — the same tier as Terminal.app and iTerm2 — because the
    /// surface is named, not guessed at from a tty.
    ///
    /// The verification is not decoration. Two of the three focus code paths in the
    /// spike returned success while raising the wrong window, so this compares the
    /// ref `rpc surface.focus` says it selected against the ref `identify` says is
    /// focused, and reports `verified: false` when they disagree.
    public func focus(_ session: Session) async -> FocusOutcome {
        await Task.detached(priority: .userInitiated) { [cli] in
            // App activation first, through the path that already works from an
            // accessory app: NSRunningApplication.activate is refused to a
            // background non-activating panel, NSWorkspace.openApplication is not.
            // FocusResolver owns that dance; there is no reason to own it twice.
            let raised = session.pid.map { FocusResolver.performFocus(pid: $0, cachedTTY: nil) }

            _ = cli.run(["select-workspace", "--workspace", session.workspaceRef])
            let selected = cli.run(["rpc", "surface.focus", #"{"surface_id":"\#(session.surfaceUUID)"}"#])
            guard !selected.failed else {
                return Self.verdict(target: session.surfaceRef, focused: nil,
                                    appRaised: raised?.verified ?? false, problem: selected.problem)
            }
            // The ref cmux says it selected, not one we remembered — a ref is
            // positional and this is the only moment it is known to be current.
            let target = CmuxSurfaceInfo.ref(inJSON: selected.out) ?? session.surfaceRef
            let focused = CmuxSurfaceInfo.focusedRef(inJSON: cli.text(["identify", "--no-caller"]))
            return Self.verdict(target: target, focused: focused,
                                appRaised: raised?.verified ?? false, problem: nil)
        }.value
    }

    /// Pure, so the self-check drives it without moving the user's windows.
    static func verdict(target: String, focused: String?, appRaised: Bool, problem: String?) -> FocusOutcome {
        func outcome(_ tier: FocusTier, _ verified: Bool, _ reason: String) -> FocusOutcome {
            FocusOutcome(tier: tier, verified: verified, reason: reason, host: "cmux",
                         tty: nil, tmuxTarget: nil, attachCommand: nil)
        }
        if let problem {
            return outcome(.impossible, false, "cmux refused to select \(target) (\(problem)).")
        }
        guard let focused else {
            return outcome(.windowAndTab, false,
                           "cmux selected \(target) but would not say what is focused — unverified.")
        }
        guard focused == target else {
            return outcome(.windowAndTab, false,
                           "cmux reported success but \(focused) is focused, not \(target).")
        }
        // The surface is right; the app may still be behind another window. Two
        // distinct outcomes, because "wrong tab" and "right tab, hidden" need
        // different sentences.
        return appRaised
            ? outcome(.windowAndTab, true, "Raises the cmux window and this surface (\(target)).")
            : outcome(.windowAndTab, false,
                      "Selected \(target) in cmux, but cmux did not come forward — another app is holding focus.")
    }

    // MARK: - Approve and reject

    public enum Answer: String, Sendable, Equatable {
        case approve
        case reject

        /// Layout-free, per task 044, and the same two answers the PTY path sends —
        /// spelled in cmux's key vocabulary rather than as raw bytes.
        ///
        /// `enter` takes whichever option the CLI has **already** selected, which is
        /// the plain "Yes" and never the rule-writing "Yes, and don't ask again".
        /// `escape` cancels, witnessed on both reject affordances. Exactly one
        /// keystroke either way: a trailing Return would answer whatever dialog came
        /// next, and on approve Return *is* the answer.
        public var key: String {
            switch self {
            case .approve: "enter"
            case .reject: "escape"
            }
        }
    }

    /// What happened. Note the absence of a `succeeded` case — deliberately.
    public enum SendOutcome: Sendable, Equatable {
        /// The pre-read did not show a prompt. **Nothing was sent.**
        case refused(String)
        /// Sent, and the post-read shows the prompt gone.
        ///
        /// This means the keystroke landed. It does **not** mean the answer was
        /// honoured, and on the reject path it must never be shown as "done".
        /// Measured: after an `escape` that the transcript proves rejected the call,
        /// the screen read `Ran 1 shell command`. The screen is a record of what was
        /// drawn, not of what was decided. Callers feed this to
        /// `StateEngine.clearNeedsInput` and let the remaining sources speak — which
        /// resolves to `unknown` if none of them can, exactly as the plan requires.
        case cleared(String)
        /// Sent, and the post-read **still** shows a prompt. Resolves to `unknown`.
        case unconfirmed(String)
        /// The CLI refused the keystroke, so nothing was delivered.
        case failed(String)
    }

    /// read → verify → send → verify. In that order, with a refusal available at
    /// every step, because this is a keystroke into somebody's real work.
    public func answer(_ answer: Answer, on session: Session) async -> SendOutcome {
        await Task.detached(priority: .userInitiated) { [cli] in
            let adapter = CmuxAdapter(cli: cli)
            // Pre-read. The gate, not a courtesy: cmux redacts `tool_input` and never
            // sends `permission_suggestions`, so the screen is the only evidence that
            // a prompt exists and what it is asking.
            let pre = adapter.screen(surfaceUUID: session.surfaceUUID)
            if let refusal = Self.preflight(pre) { return .refused(refusal) }

            let sent = cli.run(["send-key", "--surface", session.surfaceUUID, answer.key])
            guard !sent.failed else {
                return .failed("cmux would not deliver \(answer.key) to \(session.surfaceRef): \(sent.problem)")
            }

            let post = adapter.screen(surfaceUUID: session.surfaceUUID)
            return Self.confirm(post, answer: answer)
        }.value
    }

    /// The gate. `nil` means the prompt is really there and it is safe to send.
    ///
    /// An unreadable screen refuses just as firmly as an idle one: not knowing what
    /// is on a surface is not permission to type into it.
    static func preflight(_ pre: CmuxScreen) -> String? {
        switch pre {
        case .prompt:
            return nil
        case .noPrompt:
            return "no permission prompt is on screen — refusing to send a keystroke into a live session."
        case .unreadable(let why):
            return "could not read the surface (\(why)) — refusing to send a keystroke blind."
        }
    }

    /// The post-read. A prompt still standing is reported as unconfirmed, never as
    /// success, and never retried: a second keystroke would answer whatever the
    /// first one actually did.
    static func confirm(_ post: CmuxScreen, answer: Answer) -> SendOutcome {
        switch post {
        case .noPrompt:
            return .cleared("\(answer.rawValue) sent; the prompt is gone.")
        case .prompt:
            return .unconfirmed(
                "\(answer.rawValue) was sent but the prompt is still on screen — treating the result as unknown."
            )
        case .unreadable(let why):
            return .unconfirmed(
                "\(answer.rawValue) was sent but the surface could not be read back (\(why)) — treating the result as unknown."
            )
        }
    }

    // MARK: - AgentBackend

    public func dispatch(_ command: AgentCommand, to sessionID: String) async throws {
        let sessions = await Task.detached(priority: .userInitiated) { [cli] in
            CmuxAdapter.discover(cli: cli)
        }.value
        // Re-resolved every time rather than cached. A surface can close between the
        // click and the keystroke, and a stale target is how a keystroke reaches a
        // stranger's session.
        guard let session = sessions.first(where: { $0.claudeSessionID == sessionID }) else {
            throw CmuxError.unknownSession(sessionID)
        }
        switch command {
        case .focus:
            let outcome = await focus(session)
            guard outcome.verified else { throw CmuxError.unverified(outcome.reason) }
        case .approve, .reject:
            let outcome = await answer(command == .approve ? .approve : .reject, on: session)
            switch outcome {
            case .cleared:
                return
            case .refused(let why), .failed(let why), .unconfirmed(let why):
                throw CmuxError.unverified(why)
            }
        case .newSession, .sendPrompt, .setEffort:
            throw CmuxError.unsupported(Self.capabilities)
        }
    }

    public enum CmuxError: Error, Sendable, Equatable {
        case unknownSession(String)
        /// The action may or may not have happened. Never reported as done.
        case unverified(String)
        case unsupported(SessionCapabilities)
    }
}

// MARK: - The state source

public extension StateSource {
    /// cmux's own agent-hook stream.
    ///
    /// `.reported` because these are hook deliveries, not inference — the same class
    /// of evidence as `claudeHooks`, arriving over a different pipe. Downgrading it
    /// to `.inferred` would be a lie in the other direction.
    ///
    /// **The vocabulary is narrower than `claudeHooks`, and every omission was
    /// measured.** `.idle` is absent because cmux strips `notification_type`, so
    /// `idle_prompt` cannot be separated from ten unrelated notification types
    /// including login toasts. `.error` is absent because cmux forwards no
    /// `PostToolUse` at all, and therefore — on the evidence — none of its failure
    /// variants either. Saying so here is the whole job of `reportableStates`: the
    /// panel will state that idle and error are undetectable on this source rather
    /// than leave keys that can never light.
    ///
    // ponytail: known ceiling — cmux forwards no `agent_id`, so a subagent's `Stop`
    // cannot be told from the main thread's and can drive a key to `complete` early
    // (a SubagentStop landed 3.8s after the main Stop in the hook spike). Upgrade
    // path: our own ClaudeHookSource does see agent_id, and at equal confidence the
    // engine prefers the fresher reading, so installing hooks alongside this stream
    // corrects it. Filtering `Stop` outright would cost `complete` for everyone to
    // fix it for the few, which is the worse trade.
    ///
    /// 20s, and it is short on purpose: nothing re-affirms this stream between tool
    /// calls, so a session left alone must grey out rather than hold a colour it can
    /// no longer justify. Amber is the exception and is handled with evidence instead
    /// of a longer window — see `CmuxAdapter.screen(surfaceUUID:)`.
    static let cmuxEvents = StateSource(
        id: "cmux.events",
        confidence: .reported,
        reportableStates: [.running, .complete, .needsInput, .unknown],
        stalenessThreshold: 20
    )
}

// MARK: - CLI plumbing

/// One `cmux` invocation. Injected everywhere so the self-check runs on fixture
/// text and never touches the user's live sessions.
public struct CmuxCLI: Sendable {
    public struct Response: Sendable, Equatable {
        public let status: Int32
        public let out: String
        public let err: String

        /// cmux reports failure two ways: a non-zero exit, and an `Error: <code>:
        /// <message>` line. Measured across a missing surface, a missing pane and an
        /// unknown key name — all three exited 1 *and* printed the prefix. Both are
        /// checked because relying on one of two signals is how a malformed reply
        /// gets parsed as data.
        public var failed: Bool {
            status != 0 || out.hasPrefix("Error:") || err.hasPrefix("Error:")
        }

        public var problem: String {
            let text = out.hasPrefix("Error:") ? out : (err.isEmpty ? out : err)
            let first = text.split(separator: "\n").first.map(String.init) ?? ""
            return first.isEmpty ? "exit \(status)" : first
        }

        public init(status: Int32, out: String, err: String) {
            self.status = status
            self.out = out
            self.err = err
        }
    }

    public typealias Runner = @Sendable ([String]) -> Response

    public let run: Runner

    public init(run: @escaping Runner) { self.run = run }

    /// Output, or empty on any failure. Every parser below treats empty as "nothing
    /// to say" and returns nothing, so a dead socket degrades to no sessions and no
    /// readings rather than to a thrown error the UI would have to interpret.
    public func text(_ args: [String]) -> String {
        let response = run(args)
        return response.failed ? "" : response.out
    }

    /// Bundled path first, then `PATH`. Probed rather than assumed: an app that is
    /// not installed is an ordinary outcome here, not an error.
    public static let executablePath: String? = {
        let candidates = [
            "/Applications/cmux.app/Contents/Resources/bin/cmux",
            "/usr/local/bin/cmux",
            "/opt/homebrew/bin/cmux",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    public static let live = CmuxCLI { args in
        guard let path = executablePath else {
            return Response(status: -1, out: "", err: "cmux is not installed")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        // Several subcommands print a deprecation notice on the happy path
        // ("'list-workspaces' is now an alias for…"). CMUX_QUIET silences it, which
        // keeps the parsers from having to know about prose.
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_QUIET"] = "1"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return Response(status: -1, out: "", err: "\(error)") }
        // Drain before waiting, or a full pipe buffer deadlocks the child.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Response(
            status: process.terminationStatus,
            out: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
            err: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Fixture CLI, so the self-check can hand back a recorded `top` or
    /// `read-screen` without a subprocess.
    ///
    /// Matched on the full argument list first and the subcommand second. Both, not
    /// just the subcommand: discovery makes one `rpc surface.list` call *per
    /// workspace*, and a fixture that answers them all identically would prove the
    /// per-workspace scoping works when it does not. An unmatched call returns the
    /// same shape cmux returns for a bad request.
    public static func fixture(_ table: [String: Response]) -> CmuxCLI {
        CmuxCLI { args in
            table[args.joined(separator: " ")]
                ?? table[args.first ?? ""]
                ?? Response(status: 1, out: "", err: "Error: not_found: no fixture")
        }
    }
}

// MARK: - `top --format tsv`

/// The process/surface/workspace tree, parsed from TSV.
///
/// **TSV rather than the default tree format, for two reasons.** The obvious one is
/// that tree output is drawn with box characters and indentation, so parsing it means
/// reverse-engineering a rendering; the TSV is already records.
///
/// The interesting one is that tree format carries something TSV does not — `tty=`
/// on each surface row — and that field must not be used. Measured: two surfaces in
/// one pane both reported `tty=ttys007`, and the agent processes on those surfaces
/// were actually on `ttys001` and `ttys000`. The surface's `tty` is its shell's, it
/// is not unique per surface, and it is not the agent's. Keying on it would
/// reintroduce the exact recycled-tty failure the focus spike documented, in order
/// to obtain a field this adapter has no use for — every command it issues names a
/// surface directly.
public struct CmuxTopSnapshot: Sendable, Equatable {

    /// A `workspace:<UUID>:tag:<agent>` row and the agent processes hanging under it.
    public struct AgentTag: Sendable, Equatable {
        public let workspaceUUID: String
        public let workspaceRef: String
        /// `claude_code`, `codex`, …
        public let agentKind: String
        public let pids: [Int32]
        /// The tag row's own label. `Running` on three live workspaces and empty on a
        /// fourth; undocumented, so it is carried for the log and never mapped to a
        /// state. `cmux events` is the state source.
        public let statusLabel: String
    }

    /// surface ref → workspace ref, resolved through the pane row.
    public let surfaceWorkspace: [String: String]
    public let surfaceTitles: [String: String]
    public let agentTags: [AgentTag]
    /// pid → **every** surface ref that claimed it.
    ///
    /// A set, not a single value, because cmux attributes one pid to several
    /// surfaces. Measured: pid 66873 appeared under `surface:1`, under `surface:4`
    /// and under a workspace tag, and pid 66876 under the same two surfaces. Taking
    /// the first match returns `surface:1` for both — and for one of them that is
    /// simply the wrong surface, which for a keystroke is the worst kind of wrong.
    public let surfaceClaims: [Int32: Set<String>]

    /// How a pid resolved to a surface. Three outcomes, because "we cannot tell"
    /// must be representable.
    public enum Join: Sendable, Equatable {
        case resolved(String)
        /// More than one surface in the tag's own workspace claimed this pid.
        case ambiguous([String])
        /// No surface in the tag's workspace claimed it, or the pid carries no tag.
        case unclaimed

        public var resolvedRef: String? {
            if case .resolved(let ref) = self { return ref }
            return nil
        }
    }

    /// Resolve a pid to one surface, or refuse to.
    ///
    /// The disambiguator is the pid's **own workspace**, which the tag row states
    /// exactly: a tag ref embeds the workspace UUID and its parent column names the
    /// workspace ref, so `tag → workspace` is unambiguous even when
    /// `process → surface` is not. Intersecting the claiming surfaces with that
    /// workspace collapsed both measured collisions to a single candidate, and the
    /// answers matched ground truth taken independently from each process's own
    /// `CMUX_PANEL_ID`, which is the surface UUID it is running in.
    ///
    /// Verified on all four live sessions: 66873→surface:1, 66874→surface:2,
    /// 66875→surface:7, 66876→surface:4. First-match would have got two of the four
    /// wrong.
    public func join(agentPID pid: Int32) -> Join {
        guard let tag = agentTags.first(where: { $0.pids.contains(pid) }) else { return .unclaimed }
        let candidates = (surfaceClaims[pid] ?? [])
            .filter { surfaceWorkspace[$0] == tag.workspaceRef }
            .sorted()
        switch candidates.count {
        case 1: return .resolved(candidates[0])
        case 0: return .unclaimed
        default: return .ambiguous(candidates)
        }
    }

    public static func parse(tsv: String) -> CmuxTopSnapshot {
        var paneWorkspace: [String: String] = [:]
        var surfacePane: [String: String] = [:]
        var titles: [String: String] = [:]
        var claims: [Int32: Set<String>] = [:]
        var tagRows: [(uuid: String, workspace: String, kind: String, label: String, ref: String)] = []
        var tagPIDs: [String: [Int32]] = [:]

        for line in tsv.split(separator: "\n", omittingEmptySubsequences: true) {
            // cpu, memory, procCount, kind, ref, parentRef, label. Trailing fields
            // are routinely empty, so a short row is skipped rather than padded.
            let field = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard field.count >= 6 else { continue }
            let kind = field[3], ref = field[4], parent = field[5]
            let label = field.count >= 7 ? field[6] : ""

            switch kind {
            case "pane":
                paneWorkspace[ref] = parent
            case "surface":
                surfacePane[ref] = parent
                titles[ref] = label
            case "tag":
                guard let parsed = parseTagRef(ref) else { continue }
                tagRows.append((parsed.uuid, parent, parsed.kind, label, ref))
            case "process":
                guard let pid = Int32(ref) else { continue }
                if parent.hasPrefix("surface:") {
                    claims[pid, default: []].insert(parent)
                } else if parent.contains(":tag:") {
                    tagPIDs[parent, default: []].append(pid)
                }
            default:
                continue
            }
        }

        var surfaceWorkspace: [String: String] = [:]
        for (surface, pane) in surfacePane {
            if let workspace = paneWorkspace[pane] { surfaceWorkspace[surface] = workspace }
        }

        let tags = tagRows.map { row in
            AgentTag(workspaceUUID: row.uuid, workspaceRef: row.workspace, agentKind: row.kind,
                     pids: tagPIDs[row.ref] ?? [], statusLabel: row.label)
        }
        return CmuxTopSnapshot(surfaceWorkspace: surfaceWorkspace, surfaceTitles: titles,
                               agentTags: tags, surfaceClaims: claims)
    }

    /// `workspace:<UUID>:tag:<kind>`. Split from the right so a UUID containing a
    /// colon-free hex string is never mistaken for the delimiter structure.
    static func parseTagRef(_ ref: String) -> (uuid: String, kind: String)? {
        guard ref.hasPrefix("workspace:"), let marker = ref.range(of: ":tag:") else { return nil }
        let uuid = String(ref[ref.index(ref.startIndex, offsetBy: 10)..<marker.lowerBound])
        let kind = String(ref[marker.upperBound...])
        guard !uuid.isEmpty, !kind.isEmpty else { return nil }
        return (uuid, kind)
    }
}

// MARK: - `rpc surface.list`

/// One surface, from `rpc surface.list`.
///
/// This call is the reason cmux sessions are controllable at all. `resume_binding`
/// carries `kind: "claude"` and `checkpoint_id` — the Claude session id — beside the
/// surface's own UUID. So the session-to-target join needs no pid, no tty and no
/// title matching, which is precisely what the focus spike went looking for in the
/// AppleScript dictionary and did not find.
public struct CmuxSurfaceInfo: Sendable, Equatable {
    public let uuid: String
    public let ref: String
    public let title: String
    public let agentKind: String?
    public let claudeSessionID: String?
    public let cwd: String?

    public var hostsClaude: Bool { agentKind == "claude" }

    public static func parse(json: String) -> [CmuxSurfaceInfo] {
        guard let root = JSONValue.parse(Data(json.utf8)),
              let surfaces = root["surfaces"]?.arrayValue
        else { return [] }
        return surfaces.compactMap { entry in
            guard let uuid = entry["id"]?.stringValue, let ref = entry["ref"]?.stringValue,
                  !uuid.isEmpty, !ref.isEmpty
            else { return nil }
            let binding = entry["resume_binding"]
            return CmuxSurfaceInfo(
                uuid: uuid,
                ref: ref,
                title: entry["title"]?.stringValue ?? ref,
                agentKind: binding?["kind"]?.stringValue,
                claudeSessionID: binding?["checkpoint_id"]?.stringValue,
                cwd: binding?["cwd"]?.stringValue ?? entry["requested_working_directory"]?.stringValue
            )
        }
    }

    /// `surface_ref` out of an `rpc surface.focus` reply.
    static func ref(inJSON json: String) -> String? {
        JSONValue.parse(Data(json.utf8))?["surface_ref"]?.stringValue
    }

    /// `focused.surface_ref` out of an `identify` reply. The read-back that makes a
    /// focus claim falsifiable.
    static func focusedRef(inJSON json: String) -> String? {
        JSONValue.parse(Data(json.utf8))?["focused"]?["surface_ref"]?.stringValue
    }
}

// MARK: - `cmux events`

/// One line of `cmux events`, decoded.
///
/// The payload is re-parsed through `HookEvent`, and the state mapping is
/// `ClaudeHookSource.outcome(for:)` — the same 31-entry table, already proven by its
/// own self-check. A second table for the same events would drift from the first,
/// and the drift would be invisible until a key showed the wrong colour.
public struct CmuxEvent: Sendable, Equatable {
    /// Per-boot sequence. `id` is literally `<boot_id>-<seq>`, so a seq means
    /// nothing without its boot.
    public let seq: Int
    public let bootID: String
    /// `agent.hook.PreToolUse`, `surface.focused`, …
    public let name: String
    /// `received` or `completed`.
    public let phase: String?
    /// `_opencode_request_id`. Identical across both phases of one hook, which is
    /// what makes the two phases recognisable as one event rather than two.
    public let requestID: String?
    /// `_source`: `claude`, `codex`, `opencode`.
    public let agentSource: String?
    public let workspaceUUID: String?
    /// `_ppid` — the agent process. Present on every agent event measured, and the
    /// cheapest liveness handle there is.
    public let pid: Int32?
    /// `nil` when the line is not an agent hook (a `surface.focused`, say).
    public let hook: HookEvent?
    /// `_received_at`: when the hook arrived, identical in both phases. The evidence
    /// time, which is what `StateEngine` measures staleness from — not when we
    /// happened to read the line.
    public let observedAt: Date

    public var sessionID: String? { hook?.sessionID }

    /// The disposition, with the two cmux-specific gates in front of the shared
    /// table.
    public var outcome: HookOutcome {
        guard let hook else { return .ignored("not an agent hook event ('\(name)')") }
        guard agentSource == nil || agentSource == "claude" else {
            return .ignored("agent '\(agentSource ?? "?")' is not in scope for this backend")
        }
        // Phase. Both phases carry the same payload, the same `_received_at` and the
        // same request id; `completed` adds only `result.status: "acknowledged"`. So
        // `received` is the reading and `completed` is a repeat — acting on both
        // would double-count and stamp the later arrival on the same evidence.
        //
        // The tempting reading of the asymmetry is wrong and was tested: a
        // `PermissionRequest` gets a `received` and **no** `completed`, and no
        // `completed` ever arrives — not while the prompt is open and not after it is
        // answered. So a missing `completed` is not "still pending" and a present one
        // is not "answered". Neither phase can clear amber; the screen does.
        if let phase, phase != "received" {
            guard phase == "completed" else { return .ignored("unrecognised phase '\(phase)'") }
            return .ignored("phase 'completed' repeats the received hook and carries no new evidence")
        }
        let outcome = ClaudeHookSource.outcome(for: hook)
        // Keep the source inside its declared vocabulary here rather than letting the
        // engine reject it downstream. Same refusal, but the reason names cmux's
        // redaction instead of appearing as an adapter bug in `rejections`.
        if let state = outcome.state, !StateSource.cmuxEvents.reportableStates.contains(state) {
            return .ignored("\(hook.name) means \(state.rawValue), which cmux's stream cannot witness")
        }
        return outcome
    }

    /// Returns `nil` — never throws — for anything unusable: a heartbeat, a blank
    /// line, a truncated write, a non-agent event, a payload with no session id.
    public static func parse(line: String) -> CmuxEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let root = JSONValue.parse(Data(trimmed.utf8)),
              let seq = root["seq"]?.intValue,
              let name = root["name"]?.stringValue, !name.isEmpty
        else { return nil }

        let bootID = root["boot_id"]?.stringValue ?? ""
        let payload = root["payload"]
        let receivedAt = payload?["_received_at"]?.stringValue ?? root["occurred_at"]?.stringValue
        let observedAt = receivedAt.flatMap(parseTimestamp) ?? Date()

        return CmuxEvent(
            seq: seq,
            bootID: bootID,
            name: name,
            phase: payload?["phase"]?.stringValue,
            requestID: payload?["_opencode_request_id"]?.stringValue,
            agentSource: payload?["_source"]?.stringValue,
            workspaceUUID: payload?["workspace_id"]?.stringValue,
            pid: payload?["_ppid"]?.intValue.map(Int32.init),
            hook: payload.flatMap { hookEvent(from: $0, observedAt: observedAt) },
            observedAt: observedAt
        )
    }

    /// Rebuild the payload with a bare session id and let `HookEvent` do the rest.
    /// Round-tripping through JSON rather than duplicating `HookEvent`'s twenty-field
    /// initialiser keeps one definition of what a hook payload is.
    private static func hookEvent(from payload: JSONValue, observedAt: Date) -> HookEvent? {
        guard var object = payload.objectValue,
              let sessionID = object["session_id"]?.stringValue, !sessionID.isEmpty,
              object["hook_event_name"]?.stringValue?.isEmpty == false
        else { return nil }
        object["session_id"] = .string(CmuxAdapter.stripSessionPrefix(sessionID))
        guard let data = try? JSONValue.object(object).canonicalData() else { return nil }
        return HookEvent.parse(data, observedAt: observedAt)
    }

    /// `2026-07-26T22:26:29.511Z`, and the same without the fraction. Both are tried
    /// because a payload that pins a state to the wrong second is worse than one that
    /// falls back to now.
    static func parseTimestamp(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: fractional) { return date }
        return try? Date(text, strategy: whole)
    }

    private static let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let whole = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
}

/// Long-running `cmux events` reader.
///
/// **Our own `(bootID, seq)` cursor, not `--cursor-file`.** The flag exists and
/// works, but the file it writes holds a bare integer — measured, the whole content
/// was `1120` — with no boot identity. `seq` restarts from 1 when cmux restarts, so
/// a carried-over cursor of 1120 would silently skip the first 1120 events of the
/// next boot, including every `PermissionRequest` in them. Tracking the boot id
/// alongside the seq costs one comparison and makes a restart replay instead of skip.
///
/// The cross-restart gap this closes is *our* reader dying while cmux stays up. If
/// this app restarts, discovery re-snapshots anyway, which is the pairing the plan
/// asks for: a snapshot for the cold start, a stream for everything after.
private actor EventStream {
    private let cli: CmuxCLI
    private var subscribers: [UUID: AsyncStream<CmuxEvent>.Continuation] = [:]
    private var reader: Task<Void, Never>?
    private var bootID: String?
    private var lastSeq: Int?

    init(cli: CmuxCLI) { self.cli = cli }

    func add(_ token: UUID, _ continuation: AsyncStream<CmuxEvent>.Continuation) {
        subscribers[token] = continuation
        guard reader == nil else { return }
        reader = Task { await self.pump() }
    }

    func unsubscribe(_ token: UUID) {
        subscribers[token] = nil
        if subscribers.isEmpty { stop() }
    }

    func stop() {
        reader?.cancel()
        reader = nil
    }

    private func yield(_ event: CmuxEvent) {
        // A boot change means the sequence restarted; anything remembered about the
        // old one is meaningless rather than merely old.
        if event.bootID != bootID {
            bootID = event.bootID
            lastSeq = nil
        }
        lastSeq = max(lastSeq ?? 0, event.seq)
        for continuation in subscribers.values { continuation.yield(event) }
    }

    private func pump() async {
        while !Task.isCancelled {
            await readOnce()
            guard !Task.isCancelled else { return }
            // The stream ends when cmux quits or the socket drops. Reconnect on a
            // fixed delay: fast enough that a cmux restart costs one tick, slow
            // enough that a permanently absent cmux is not a spin loop.
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func readOnce() async {
        guard let path = CmuxCLI.executablePath else { return }
        var args = ["events", "--category", "agent", "--no-heartbeat", "--no-ack"]
        if let lastSeq { args += ["--after", String(lastSeq)] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_QUIET"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return }

        // Cancellation has to reach the child, not just the task: an abandoned
        // `cmux events` would hold its socket subscription open forever.
        defer {
            if process.isRunning { process.terminate() }
        }
        do {
            for try await line in pipe.fileHandleForReading.bytes.lines {
                if Task.isCancelled { return }
                if let event = CmuxEvent.parse(line: line) { yield(event) }
            }
        } catch {
            return
        }
    }
}

// MARK: - Reading the screen

/// What `read-screen` shows, reduced to the one question that gates a keystroke.
public enum CmuxScreen: Sendable, Equatable {
    /// A modal prompt is up, with its numbered options.
    case prompt(question: String, options: [String])
    case noPrompt
    /// Nothing readable came back. Distinct from `noPrompt`, and treated as a
    /// refusal: not knowing is not permission.
    case unreadable(String)

    /// Two markers, both required.
    ///
    /// Measured on the two dialogs Claude Code actually shows — the tool permission
    /// prompt ("Do you want to proceed?" / `❯ 1. Yes` / "Esc to cancel · Tab to
    /// amend") and the folder-trust prompt ("…one you trust?" / `❯ 1. Yes, I trust
    /// this folder` / "Enter to confirm · Esc to cancel"). What they share is a
    /// selected **numbered** option row and an "Esc to cancel" footer.
    ///
    /// **`❯` alone is not a prompt, and this is the trap.** The ordinary input line
    /// begins with the same glyph, and Claude Code renders a dimmed *suggested*
    /// follow-up inside it — a screen with nothing typed and no dialog open read
    /// `❯ cat note.txt again` immediately after a turn finished. A detector keyed on
    /// `❯` would call that a prompt and then send Return into an idle session, which
    /// would submit the suggestion. Requiring a digit and a period after the marker
    /// separates them, and requiring the footer as well means a half-drawn frame
    /// does not qualify either.
    public static func parse(_ screen: String) -> CmuxScreen {
        guard !screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unreadable("the surface returned nothing")
        }
        let lines = screen.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var options: [String] = []
        var selectedNumbered = false
        for line in lines {
            guard let option = numberedOption(line) else { continue }
            options.append(option.text)
            if option.selected { selectedNumbered = true }
        }
        let footer = lines.contains { $0.contains("Esc to cancel") }
        guard selectedNumbered, footer, !options.isEmpty else { return .noPrompt }

        // The question is the last line ending in "?" above the options; absent one,
        // the empty string. A prompt with an unrecognised question is still a prompt,
        // so this never turns into a refusal.
        let firstOptionIndex = lines.firstIndex { numberedOption($0) != nil } ?? 0
        let question = lines[..<firstOptionIndex]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasSuffix("?") } ?? ""
        return .prompt(question: question, options: options)
    }

    /// `❯ 1. Yes` or `  2. No`. The marker may be absent (an unselected row) but the
    /// number and the period may not.
    private static func numberedOption(_ line: String) -> (selected: Bool, text: String)? {
        var rest = Substring(line)
        while let first = rest.first, first == " " || first == "\t" { rest = rest.dropFirst() }
        var selected = false
        if let first = rest.first, first == "❯" || first == ">" {
            selected = true
            rest = rest.dropFirst()
            while let first = rest.first, first == " " { rest = rest.dropFirst() }
        }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.first == "." else { return nil }
        rest = rest.dropFirst()
        guard rest.first == " " || rest.isEmpty else { return nil }
        return (selected, rest.trimmingCharacters(in: .whitespaces))
    }

    public var isPrompt: Bool {
        if case .prompt = self { return true }
        return false
    }
}

// MARK: - Self check

public extension CmuxAdapter {
    /// Human-readable failures, empty when healthy. Wire into `SelfCheck` with:
    ///
    ///     failures += CmuxAdapter.selfCheckFailures().map { "cmux: \($0)" }
    ///
    /// Every input is fixture text captured from the live CLI on 2026-07-26 and then
    /// frozen. Nothing here launches a subprocess, reads a socket, or depends on cmux
    /// being installed — a check that only passes while the user has four sessions
    /// open is not a check.
    static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // MARK: The TSV join, including the duplicate pid
        //
        // Verbatim rows from the live tree, reduced to the four workspaces and the
        // two collisions. 66873 and 66876 are each claimed by surface:1 AND
        // surface:4; their tags put them in different workspaces. Ground truth from
        // each process's own CMUX_PANEL_ID: 66873 → surface:1, 66876 → surface:4.
        let tsv = """
        35.0\t3908967632\t69\ttotal\ttotal\t\t
        35.0\t3908967632\t69\twindow\twindow:1\ttotal\t
        4.3\t644663240\t1\tprocess\t64629\twindow:1\tcmux
        22.8\t618650648\t11\tworkspace\tworkspace:2\twindow:1\tCODEX-MICRO
        5.1\t584570704\t9\ttag\tworkspace:E0D7E41C-3CE4-460A-8D33-0FB7CB6028AC:tag:claude_code\tworkspace:2\tRunning
        5.1\t404981128\t1\tprocess\t66874\tworkspace:E0D7E41C-3CE4-460A-8D33-0FB7CB6028AC:tag:claude_code\t2.1.220
        22.8\t618650648\t11\tpane\tpane:2\tworkspace:2\t
        22.8\t618650648\t11\tsurface\tsurface:2\tpane:2\t⠂ codex-micro
        5.1\t404981128\t1\tprocess\t66874\tsurface:2\t2.1.220
        0.0\t4506008\t1\tsurface\tsurface:3\tpane:2\twagnerjosedasilva@Mac:~/Downloads
        0.0\t4506008\t1\tprocess\t67615\tsurface:3\tzsh
        0.0\t4506008\t1\tprocess\t67615\tsurface:2\tzsh
        7.4\t2004885264\t45\tworkspace\tworkspace:1\twindow:1\t⠐ magneto
        5.6\t614848096\t6\ttag\tworkspace:FA1EEA4E-064E-4223-86AB-37F0889D5D47:tag:claude_code\tworkspace:1\tRunning
        5.6\t437634416\t1\tprocess\t66873\tworkspace:FA1EEA4E-064E-4223-86AB-37F0889D5D47:tag:claude_code\t2.1.220
        7.4\t2004885264\t45\tpane\tpane:1\tworkspace:1\t
        7.3\t1994922520\t41\tsurface\tsurface:1\tpane:1\t⠐ magneto
        5.6\t437634416\t1\tprocess\t66873\tsurface:1\t2.1.220
        0.6\t235488408\t1\tprocess\t66876\tsurface:1\t2.1.220
        3.1\t1076753472\t16\tworkspace\tworkspace:3\twindow:1\tcan
        1.5\t405083144\t5\ttag\tworkspace:B66C5EBA-5AE0-481C-A7D6-C6EBB2E6C3BB:tag:claude_code\tworkspace:3\t
        1.5\t405083144\t1\tprocess\t66876\tworkspace:B66C5EBA-5AE0-481C-A7D6-C6EBB2E6C3BB:tag:claude_code\t2.1.220
        3.1\t1072231080\t15\tpane\tpane:3\tworkspace:3\t
        3.1\t1000697168\t13\tsurface\tsurface:4\tpane:3\t✳ Confirm current directory
        0.6\t235488408\t1\tprocess\t66876\tsurface:4\t2.1.220
        5.6\t437634416\t1\tprocess\t66873\tsurface:4\t2.1.220
        2.4\t563335584\t8\tworkspace\tworkspace:4\twindow:1\tGCP
        2.4\t558829576\t7\ttag\tworkspace:E743E302-741F-4964-93EC-5B42439283A6:tag:claude_code\tworkspace:4\tRunning
        2.4\t558829576\t1\tprocess\t66875\tworkspace:E743E302-741F-4964-93EC-5B42439283A6:tag:claude_code\t2.1.220
        2.4\t563335584\t8\tpane\tpane:5\tworkspace:4\t
        2.4\t563335584\t8\tsurface\tsurface:7\tpane:5\t✳ Create Google Cloud PDE page
        2.4\t558829576\t1\tprocess\t66875\tsurface:7\t2.1.220
        """
        let top = CmuxTopSnapshot.parse(tsv: tsv)

        check("tsv lost a workspace tag", top.agentTags.count == 4)
        check("tag ref did not yield its workspace uuid",
              top.agentTags.contains { $0.workspaceUUID == "FA1EEA4E-064E-4223-86AB-37F0889D5D47" })
        check("tag ref did not yield its agent kind",
              top.agentTags.allSatisfy { $0.agentKind == "claude_code" })
        check("tag row lost its status label",
              top.agentTags.contains { $0.statusLabel == "Running" }
                  && top.agentTags.contains { $0.statusLabel.isEmpty })
        check("surface did not resolve to its workspace through the pane",
              top.surfaceWorkspace["surface:4"] == "workspace:3"
                  && top.surfaceWorkspace["surface:2"] == "workspace:2")
        check("surface title lost", top.surfaceTitles["surface:1"] == "⠐ magneto")

        // The point of the whole parse. Both collisions must land on the surface the
        // process environment independently confirms, and a first-match join would
        // put both on surface:1.
        check("duplicate pid not recorded as multiple claims",
              (top.surfaceClaims[66873] ?? []) == ["surface:1", "surface:4"])
        check("66873 must join to surface:1", top.join(agentPID: 66873) == .resolved("surface:1"))
        check("66876 must join to surface:4", top.join(agentPID: 66876) == .resolved("surface:4"))
        check("66874 must join to surface:2", top.join(agentPID: 66874) == .resolved("surface:2"))
        check("66875 must join to surface:7", top.join(agentPID: 66875) == .resolved("surface:7"))
        check("first-match join would have been wrong here",
              (top.surfaceClaims[66876] ?? []).sorted().first == "surface:1")
        // A pid with no tag has no workspace to disambiguate with, so it must refuse
        // rather than pick the one surface that happens to claim it.
        check("an untagged pid must not resolve", top.join(agentPID: 67615) == .unclaimed)
        check("an unknown pid must not resolve", top.join(agentPID: 999_999) == .unclaimed)

        // Genuine ambiguity — two surfaces in the tag's own workspace — must refuse.
        let ambiguousTSV = """
        1.0\t1\t1\tworkspace\tworkspace:9\twindow:1\tW
        1.0\t1\t1\ttag\tworkspace:AAA:tag:claude_code\tworkspace:9\tRunning
        1.0\t1\t1\tprocess\t4242\tworkspace:AAA:tag:claude_code\t2.1.220
        1.0\t1\t1\tpane\tpane:9\tworkspace:9\t
        1.0\t1\t1\tsurface\tsurface:20\tpane:9\tone
        1.0\t1\t1\tsurface\tsurface:21\tpane:9\ttwo
        1.0\t1\t1\tprocess\t4242\tsurface:20\t2.1.220
        1.0\t1\t1\tprocess\t4242\tsurface:21\t2.1.220
        """
        check("two candidates in one workspace must be ambiguous, not a guess",
              CmuxTopSnapshot.parse(tsv: ambiguousTSV).join(agentPID: 4242)
                  == .ambiguous(["surface:20", "surface:21"]))

        check("tag ref parser accepted a non-tag",
              CmuxTopSnapshot.parseTagRef("workspace:2") == nil)
        check("tag ref parser lost the uuid",
              CmuxTopSnapshot.parseTagRef("workspace:AAA-BBB:tag:codex")?.uuid == "AAA-BBB")
        check("tag ref parser lost the kind",
              CmuxTopSnapshot.parseTagRef("workspace:AAA-BBB:tag:codex")?.kind == "codex")

        // MARK: Malformed and empty TSV degrade to nothing
        for (label, text) in [
            ("empty", ""),
            ("blank lines", "\n\n\n"),
            ("short rows", "1\t2\t3\n"),
            ("error text", "Error: not_found: Surface not found"),
            ("html", "<html>nope</html>"),
            ("header only", "CPU%\tMEMORY\tPROC\tNODE"),
        ] {
            let snapshot = CmuxTopSnapshot.parse(tsv: text)
            check("malformed tsv '\(label)' should yield no tags", snapshot.agentTags.isEmpty)
            check("malformed tsv '\(label)' should resolve nothing",
                  snapshot.join(agentPID: 66873) == .unclaimed)
        }

        // MARK: surface.list — the session id join
        let surfaceListJSON = """
        {"surfaces":[
          {"focused":true,"id":"C0E84EC3-F4DD-4599-9946-C188595DF2AA","ref":"surface:4",
           "title":"✳ Confirm current directory","type":"terminal",
           "requested_working_directory":"/Users/w/personal/sql-roullete",
           "resume_binding":{"kind":"claude","name":"Claude Code",
             "checkpoint_id":"869dd43a-ebe1-4f92-8e28-a6ea7dda4000",
             "cwd":"/Users/w/.claude/skills/linkedin-carousel","source":"agent-hook"}},
          {"focused":false,"id":"7F45CF85-D379-44D2-A890-765EBFFDAA1C","ref":"surface:5",
           "title":"w@Mac:~/personal/sql-roullete","type":"terminal","resume_binding":null}
        ],"workspace_id":"B66C5EBA-5AE0-481C-A7D6-C6EBB2E6C3BB"}
        """
        let listed = CmuxSurfaceInfo.parse(json: surfaceListJSON)
        check("surface.list lost a surface", listed.count == 2)
        check("agent surface not recognised", listed.first?.hostsClaude == true)
        check("a plain shell surface must not look like an agent",
              listed.last?.hostsClaude == false && listed.last?.claudeSessionID == nil)
        check("checkpoint_id is the session id",
              listed.first?.claudeSessionID == "869dd43a-ebe1-4f92-8e28-a6ea7dda4000")
        check("surface uuid lost", listed.first?.uuid == "C0E84EC3-F4DD-4599-9946-C188595DF2AA")
        check("resume_binding cwd should win over the requested directory",
              listed.first?.cwd == "/Users/w/.claude/skills/linkedin-carousel")
        for (label, text) in [
            ("empty", ""), ("not json", "Error: not_found: x"), ("truncated", #"{"surfaces":[{"id""#),
            ("array root", "[1,2,3]"), ("no surfaces", "{}"),
            ("surface with no id", #"{"surfaces":[{"ref":"surface:1"}]}"#),
        ] {
            check("malformed surface.list '\(label)' must yield nothing",
                  CmuxSurfaceInfo.parse(json: text).isEmpty)
        }
        check("surface.focus reply ref",
              CmuxSurfaceInfo.ref(inJSON: #"{"surface_id":"A","surface_ref":"surface:12"}"#) == "surface:12")
        check("identify focused ref",
              CmuxSurfaceInfo.focusedRef(inJSON: #"{"focused":{"surface_ref":"surface:10"}}"#) == "surface:10")
        check("identify with no focused block", CmuxSurfaceInfo.focusedRef(inJSON: "{}") == nil)

        // MARK: The claude- prefix
        check("claude- prefix not stripped",
              stripSessionPrefix("claude-f401fc26-ad2d-41e5-b08b-fb2e3e5d3bc8")
                  == "f401fc26-ad2d-41e5-b08b-fb2e3e5d3bc8")
        check("stripping must be idempotent",
              stripSessionPrefix("f401fc26-ad2d-41e5-b08b-fb2e3e5d3bc8")
                  == "f401fc26-ad2d-41e5-b08b-fb2e3e5d3bc8")
        check("a uuid beginning with the letters of an agent must survive",
              stripSessionPrefix("claudeXf401fc26") == "claudeXf401fc26")

        // MARK: Events
        //
        // Captured verbatim, including the redactions. `tool_input: null` and the
        // absent `permission_suggestions` are the reason the screen is the gate.
        func eventLine(_ hook: String, phase: String, extra: String = "") -> String {
            """
            {"boot_id":"355F3E42-84E8-4D00-A6A7-DBAA365949CE","category":"agent",
             "id":"355F3E42-84E8-4D00-A6A7-DBAA365949CE-1340","name":"agent.hook.\(hook)",
             "occurred_at":"2026-07-26T22:26:29.515Z","seq":1340,"source":"claude",
             "surface_id":null,"type":"event","version":1,
             "workspace_id":"E3A268D6-E603-4756-AC89-4141BF80021B",
             "payload":{"_opencode_request_id":"claude-f401fc26-PermissionRequest-Bash-1785104789501",
               "_ppid":93550,"_received_at":"2026-07-26T22:26:29.511Z","_source":"claude",
               "context":null,"cwd":"/tmp/probe","hook_event_name":"\(hook)","phase":"\(phase)",
               "redacted_fields":["tool_input","context"],
               "session_id":"claude-f401fc26-ad2d-41e5-b08b-fb2e3e5d3bc8",
               "tool_input":null,"tool_name":"Bash",
               "workspace_id":"E3A268D6-E603-4756-AC89-4141BF80021B"\(extra)}}
            """
        }

        guard let permission = CmuxEvent.parse(line: eventLine("PermissionRequest", phase: "received")) else {
            return failures + ["could not parse a PermissionRequest fixture"]
        }
        check("PermissionRequest must be needsInput", permission.outcome == .state(.needsInput))
        check("event lost its seq", permission.seq == 1340)
        check("event lost its boot id", permission.bootID == "355F3E42-84E8-4D00-A6A7-DBAA365949CE")
        check("event lost the agent pid", permission.pid == 93550)
        check("event lost the workspace", permission.workspaceUUID == "E3A268D6-E603-4756-AC89-4141BF80021B")
        check("session id must arrive stripped",
              permission.sessionID == "f401fc26-ad2d-41e5-b08b-fb2e3e5d3bc8")
        check("observedAt must come from _received_at, not occurred_at",
              abs(permission.observedAt.timeIntervalSince1970 - 1_785_104_789.511) < 0.002)
        check("redacted tool_input must not be invented", permission.hook?.toolInput == nil
              || permission.hook?.toolInput == JSONValue.null)
        check("cmux never sends permission_suggestions, so none may be claimed",
              permission.hook?.permissionSuggestions == nil)
        check("tool_name survives redaction", permission.hook?.toolName == "Bash")

        if let preTool = CmuxEvent.parse(line: eventLine("PreToolUse", phase: "received")) {
            check("PreToolUse must be running", preTool.outcome == .state(.running))
        } else {
            failures.append("could not parse a PreToolUse fixture")
        }
        if let prompt = CmuxEvent.parse(line: eventLine("UserPromptSubmit", phase: "received")) {
            check("UserPromptSubmit must be running", prompt.outcome == .state(.running))
        }
        if let stop = CmuxEvent.parse(line: eventLine("Stop", phase: "received")) {
            check("Stop must be complete", stop.outcome == .state(.complete))
        }

        // Phase, handled deliberately: `received` is the reading, `completed` is the
        // same hook again. Measured identical payloads bar `result.status`.
        for hook in ["PreToolUse", "Stop", "UserPromptSubmit", "PermissionRequest"] {
            guard let completed = CmuxEvent.parse(
                line: eventLine(hook, phase: "completed", extra: #","result":{"status":"acknowledged"}"#)
            ) else {
                failures.append("could not parse a completed \(hook) fixture")
                continue
            }
            check("\(hook) phase=completed must not produce a second reading",
                  completed.outcome.state == nil)
            if case .ignored(let why) = completed.outcome {
                check("the completed phase must say why it was ignored", why.contains("completed"))
            } else {
                failures.append("\(hook) phase=completed produced \(completed.outcome)")
            }
        }
        if let odd = CmuxEvent.parse(line: eventLine("Stop", phase: "dispatched")) {
            check("an unrecognised phase must not be mapped", odd.outcome.state == nil)
        }

        // The two events cmux forwards that it cannot make usable.
        if let notification = CmuxEvent.parse(line: eventLine("Notification", phase: "received")) {
            check("Notification must be ignored — cmux strips notification_type",
                  notification.outcome.state == nil)
        }
        if let subagent = CmuxEvent.parse(line: eventLine("SubagentStop", phase: "received")) {
            check("SubagentStop must not move the parent slot", subagent.outcome.state == nil)
        }

        // Vocabulary gate: anything cmux's source cannot report is refused here with
        // a reason rather than sent on to be rejected by the engine.
        if let failure = CmuxEvent.parse(line: eventLine("StopFailure", phase: "received")) {
            check("a state outside the declared vocabulary must be refused here",
                  failure.outcome.state == nil)
        }
        for state in StateSource.cmuxEvents.reportableStates {
            check("cmuxEvents declares \(state.rawValue) but claudeHooks cannot report it",
                  StateSource.claudeHooks.reportableStates.contains(state))
        }
        check("cmux must not claim it can see idle",
              !StateSource.cmuxEvents.reportableStates.contains(.idle))
        check("cmux must not claim it can see error",
              !StateSource.cmuxEvents.reportableStates.contains(.error))

        // A different agent on the same stream is not this backend's business.
        let codexLine = eventLine("Stop", phase: "received")
            .replacingOccurrences(of: #""_source":"claude""#, with: #""_source":"codex""#)
        if let codex = CmuxEvent.parse(line: codexLine) {
            check("a codex event must not drive a claude slot", codex.outcome.state == nil)
        }

        // Non-agent lines and malformed lines are dropped, never guessed at.
        let paneLine = """
        {"boot_id":"B","category":"pane","name":"pane.focused","seq":2,"type":"event",
         "payload":{"pane_id":"X","origin":"bonsplit_selection"}}
        """
        if let pane = CmuxEvent.parse(line: paneLine) {
            check("a pane event must carry no hook", pane.hook == nil)
            check("a pane event must produce no state", pane.outcome.state == nil)
        } else {
            failures.append("a non-agent event should still parse as an envelope")
        }
        for (label, line) in [
            ("empty", ""), ("whitespace", "   \n"), ("not json", "PONG"),
            ("truncated", #"{"seq":1,"name":"agent.hook.Stop","payl"#),
            ("array", "[1,2]"), ("no seq", #"{"name":"agent.hook.Stop"}"#),
            ("no name", #"{"seq":1}"#), ("empty name", #"{"seq":1,"name":""}"#),
            ("error line", "Error: invalid_params: Unknown key"),
        ] {
            check("malformed event '\(label)' must be dropped", CmuxEvent.parse(line: line) == nil)
        }
        // A payload with no session id is unattributable, so it maps to nothing.
        if let orphan = CmuxEvent.parse(
            line: #"{"seq":9,"name":"agent.hook.Stop","boot_id":"B","payload":{"hook_event_name":"Stop"}}"#
        ) {
            check("an event with no session id must not produce a reading", orphan.outcome.state == nil)
        }
        check("timestamp without a fraction must still parse",
              CmuxEvent.parseTimestamp("2026-07-26T22:26:29Z") != nil)
        check("a nonsense timestamp must not parse", CmuxEvent.parseTimestamp("yesterday") == nil)

        // MARK: The screen — captured from the real dialogs
        let permissionScreen = """
          ⎿  $ /bin/echo vcm-probe

        ───────────────────────────────────────────────────────────────
         Bash command

           /bin/echo vcm-probe
           Echo the string vcm-probe

         This command requires approval

         Do you want to proceed?
         ❯ 1. Yes
           2. Yes, and don’t ask again for: /bin/echo vcm-probe *
           3. No

         Esc to cancel · Tab to amend · ctrl+e to explain
        """
        let trustScreen = """
         Quick safety check: Is this a project you created or one you trust?

         Claude Code'll be able to read, edit, and execute files here.

         ❯ 1. Yes, I trust this folder
           2. No, exit

         Enter to confirm · Esc to cancel
        """
        // The idle screen that broke a `❯`-only detector: nothing is typed and no
        // dialog is open, but the input line carries a dimmed suggestion.
        let idleScreen = """
        ⏺ Output: vcm-probe

        ✻ Cogitated for 3s
                                                          ● high · /effort
        ───────────────────────────────────────────────────────────────
        ❯ cat note.txt again
        ───────────────────────────────────────────────────────────────
          ⏸ manual mode on · ? for shortcuts · ← for agents
        """

        guard case .prompt(let question, let options) = CmuxScreen.parse(permissionScreen) else {
            return failures + ["the real permission prompt was not detected"]
        }
        check("prompt question lost", question == "Do you want to proceed?")
        check("prompt options lost", options.count == 3 && options.first == "Yes")
        check("the rule-writing option must be readable, not silently first",
              options[1].hasPrefix("Yes, and don’t ask again"))
        check("the trust dialog is also a prompt", CmuxScreen.parse(trustScreen).isPrompt)
        check("an idle screen with a suggested prompt must NOT read as a prompt",
              CmuxScreen.parse(idleScreen) == .noPrompt)
        // The case the digit rule exists for, and the one the footer rule cannot
        // catch on its own: the input line carries a suggestion *and* a cancel hint
        // is still on screen. `❯` plus a footer is not a dialog. Getting this wrong
        // sends Return into an idle session, which submits the suggestion.
        check("a suggested input line beside a stale cancel hint is still not a prompt",
              CmuxScreen.parse("❯ cat note.txt again\n Esc to cancel · Tab to amend") == .noPrompt)

        // A numbered list with no footer, and a footer with no list, are each half a
        // dialog. Both must be refused.
        check("a numbered list alone is not a prompt",
              CmuxScreen.parse("❯ 1. Yes\n  2. No") == .noPrompt)
        check("a footer alone is not a prompt",
              CmuxScreen.parse("something happened\n Esc to cancel") == .noPrompt)
        check("an unselected list is not an open dialog",
              CmuxScreen.parse("  1. Yes\n  2. No\n Esc to cancel") == .noPrompt)
        for (label, text) in [("empty", ""), ("whitespace", "  \n\t\n")] {
            if case .unreadable = CmuxScreen.parse(text) {} else {
                failures.append("an \(label) screen must be unreadable, not noPrompt")
            }
        }

        // MARK: The verified send sequence
        //
        // Pre-read gates, post-read decides, and neither can produce a success.
        check("a pre-read with no prompt must refuse to send",
              preflight(.noPrompt) != nil)
        check("an unreadable pre-read must refuse to send",
              preflight(.unreadable("socket closed")) != nil)
        check("a refusal must say a keystroke was not sent",
              (preflight(.noPrompt) ?? "").contains("refusing"))
        check("a real prompt must be allowed through",
              preflight(.prompt(question: "Do you want to proceed?", options: ["Yes", "No"])) == nil)

        for answer in [Answer.approve, Answer.reject] {
            check("\(answer.rawValue): a cleared prompt must be reported as cleared",
                  confirm(.noPrompt, answer: answer) == .cleared("\(answer.rawValue) sent; the prompt is gone."))
            // The one that matters: the prompt is still up, so we do not know.
            if case .unconfirmed(let why) = confirm(
                .prompt(question: "Do you want to proceed?", options: ["Yes"]), answer: answer
            ) {
                check("\(answer.rawValue): unconfirmed must say the result is unknown", why.contains("unknown"))
            } else {
                failures.append("\(answer.rawValue): a post-read still showing the prompt must be unconfirmed")
            }
            if case .unconfirmed = confirm(.unreadable("nothing came back"), answer: answer) {} else {
                failures.append("\(answer.rawValue): an unreadable post-read must be unconfirmed, not cleared")
            }
        }
        // Layout-free, per task 044: one keystroke, and never a digit.
        check("approve must be Return", Answer.approve.key == "enter")
        check("reject must be ESC", Answer.reject.key == "escape")
        check("no answer may be an option index",
              !Answer.allKeys.contains { $0.allSatisfy(\.isNumber) })

        // MARK: Capabilities
        check("cmux must be able to focus", capabilities.contains(.focus))
        check("cmux must be able to approve", capabilities.contains(.approve))
        check("cmux must be able to reject", capabilities.contains(.reject))
        check("cmux must be richer than observed", capabilities != .observed)
        check("cmux is not an owned session", capabilities != .owned)
        check("sendPrompt has no verification rule yet, so it must stay off",
              !capabilities.contains(.sendPrompt))
        check("setEffort has no verification rule yet, so it must stay off",
              !capabilities.contains(.setEffort))

        // MARK: Focus, through FocusResolver's vocabulary
        let raised = verdict(target: "surface:10", focused: "surface:10", appRaised: true, problem: nil)
        check("cmux must now be tier 1, not tier 2", raised.tier == .windowAndTab)
        check("a verified raise must be verified", raised.verified)
        check("cmux focus must name the host", raised.host == "cmux")
        let wrongSurface = verdict(target: "surface:10", focused: "surface:12", appRaised: true, problem: nil)
        check("focusing the wrong surface must not report verified", !wrongSurface.verified)
        check("a wrong-surface reason must name both", wrongSurface.reason.contains("surface:12"))
        let hidden = verdict(target: "surface:10", focused: "surface:10", appRaised: false, problem: nil)
        check("right surface behind another app must not be verified", !hidden.verified)
        check("a hidden window must say cmux did not come forward",
              hidden.reason.contains("did not come forward"))
        let refused = verdict(target: "surface:10", focused: nil, appRaised: true,
                              problem: "Error: not_found: Surface not found")
        check("a refused select must be tier 3", refused.tier == .impossible)
        check("a refused select must not be verified", !refused.verified)
        let mute = verdict(target: "surface:10", focused: nil, appRaised: true, problem: nil)
        check("a silent identify must be unverified, not assumed good", !mute.verified)
        check("a focus outcome arrived with no reason to show the user",
              ![raised, wrongSurface, hidden, refused, mute].contains { $0.reason.isEmpty })

        // MARK: The CLI boundary degrades rather than throws
        let dead = CmuxCLI.fixture([:])
        check("a missing CLI must yield no text", dead.text(["top"]).isEmpty)
        check("a missing CLI must yield no sessions", CmuxAdapter(cli: dead).discover().isEmpty)
        let broken = CmuxCLI.fixture([
            "top": .init(status: 0, out: "Error: not_found: nothing", err: ""),
            "rpc": .init(status: 0, out: "", err: ""),
        ])
        check("an Error: reply on a zero exit must still count as failed",
              broken.run(["top"]).failed)
        check("an error reply must yield no sessions", CmuxAdapter(cli: broken).discover().isEmpty)
        check("a failure must carry a problem to log", !broken.run(["top"]).problem.isEmpty)
        check("a good reply is not failed",
              !CmuxCLI.Response(status: 0, out: "PONG", err: "").failed)

        // End to end on fixtures. Two of the four tagged workspaces answer with an
        // agent surface and two answer with nothing, so this also proves discovery
        // asks per workspace rather than once — and that the pid attached to each
        // session is the one the workspace-scoped join produced, not the first
        // surface that happened to claim it.
        func surfaceListCall(_ workspaceUUID: String) -> String {
            ["rpc", "surface.list", #"{"workspace_id":"\#(workspaceUUID)"}"#].joined(separator: " ")
        }
        let magnetoJSON = """
        {"surfaces":[{"id":"7A1FA0C4-3E3E-4B06-821C-502E27682326","ref":"surface:1",
          "title":"⠐ magneto","resume_binding":{"kind":"claude",
          "checkpoint_id":"2eb8827d-6375-4e42-8f35-d1b01eb398f0","cwd":"/Users/w/personal/magneto"}}]}
        """
        let wired = CmuxCLI.fixture([
            "top": .init(status: 0, out: tsv, err: ""),
            surfaceListCall("B66C5EBA-5AE0-481C-A7D6-C6EBB2E6C3BB"): .init(status: 0, out: surfaceListJSON, err: ""),
            surfaceListCall("FA1EEA4E-064E-4223-86AB-37F0889D5D47"): .init(status: 0, out: magnetoJSON, err: ""),
            // The other two tagged workspaces answer with nothing readable, which is
            // what a closed workspace or a dropped socket looks like.
            "rpc": .init(status: 0, out: "", err: ""),
        ])
        let discovered = CmuxAdapter(cli: wired).discover()
        check("discovery must ask per workspace and keep only the ones that answered",
              discovered.count == 2)
        check("an unanswered workspace must contribute nothing, not a placeholder",
              !discovered.contains { $0.claudeSessionID.isEmpty })
        if let magneto = discovered.first(where: { $0.surfaceRef == "surface:1" }) {
            // The other half of the collision: 66873 claimed surface:1 and surface:4.
            check("surface:1 must be joined to 66873, not 66876", magneto.pid == 66873)
            check("surface:1 session id lost", magneto.claudeSessionID == "2eb8827d-6375-4e42-8f35-d1b01eb398f0")
        } else {
            failures.append("discovery lost the surface:1 session")
        }
        if let session = discovered.first(where: { $0.surfaceRef == "surface:4" }) {
            check("discovered session id must be the bare uuid",
                  session.claudeSessionID == "869dd43a-ebe1-4f92-8e28-a6ea7dda4000")
            check("discovered session must target a uuid, not a ref",
                  session.surfaceUUID == "C0E84EC3-F4DD-4599-9946-C188595DF2AA")
            check("discovered session must carry the joined pid", session.pid == 66876)
            check("discovered session must be capability-gated",
                  session.agentSession.capabilities == capabilities)
            check("discovered session must name the cmux backend", session.agentSession.backendID == "cmux")
        } else {
            failures.append("discovery lost the surface:4 session")
        }

        return failures
    }
}

private extension CmuxAdapter.Answer {
    /// Both keystrokes, for the assertion that neither is an option index.
    static var allKeys: [String] { [CmuxAdapter.Answer.approve.key, CmuxAdapter.Answer.reject.key] }
}
