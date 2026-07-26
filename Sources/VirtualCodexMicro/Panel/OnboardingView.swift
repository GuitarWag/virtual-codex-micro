import AppKit
import SwiftUI

/// First-run explanation of what this app needs, what it will do to get it, and
/// what stops working if you say no.
///
/// Three rules shaped this screen, and each one came from a spike rather than
/// from taste:
///
/// 1. **Explain before the OS asks.** A macOS permission dialog gives the user
///    two buttons and no context. The Automation prompt fires on the first Apple
///    Event to a target app and writes a permanent TCC decision, so anything
///    that trips it before the user has read why is not recoverable by us. That
///    is why nothing here probes on appearance and why
///    `FocusResolver.warmUp()` is reached only through a button.
/// 2. **Show the edit, do not describe it.** Installing hooks rewrites
///    `~/.claude/settings.json`, the user's live Claude Code config.
///    `ClaudeHookInstaller` deliberately separates `plan(_:)` from `apply(_:)`
///    precisely so this view can put the real line diff on screen first, and it
///    reports `reformatsFile` so the user hears about the re-serialization
///    before their formatting changes rather than afterwards.
/// 3. **Declining must cost something specific.** "Reduced functionality" is not
///    an honest description of what happens without hooks. A pending permission
///    prompt writes no transcript record at all, so `needsInput` becomes
///    unobservable and the amber key never lights. A user who declines and then
///    trusts a calm key is worse off than one who never installed this app, so
///    the consequence is stated in those words. `selfCheckFailures()` asserts on
///    the string.
///
/// Deliberately not a wizard. The activation metric is binding a first key
/// inside two minutes, so this is one scrollable surface with per-item actions
/// and a "bind a key" escape at the top. Every step has a skip that leaves the
/// app usable; nothing here dead-ends.
public struct OnboardingView: View {

    // MARK: - Steps

    /// The four things a user will wonder about. Only two of them are ever
    /// requested — Accessibility and the microphone are listed *because* they are
    /// not, since their absence from System Settings is otherwise indistinguishable
    /// from us having forgotten to ask.
    public enum Step: String, CaseIterable, Sendable, Identifiable {
        case hooks
        case automation
        case accessibility
        case microphone

        public var id: String { rawValue }

        /// True for the two the app actually asks for. The other two are
        /// informational and have no action attached.
        public var isRequested: Bool { self == .hooks || self == .automation }
    }

    /// What we currently know about one permission. `notYetRequested` and
    /// `unknown` are different facts: the first means macOS has not been asked,
    /// the second means we asked our own filesystem and could not tell.
    public enum Grant: String, Sendable, CaseIterable {
        case installed
        case notInstalled
        case granted
        case denied
        case notYetRequested
        case notRequired
        case unknown

        public var label: String {
            switch self {
            case .installed: "installed"
            case .notInstalled: "not installed"
            case .granted: "granted"
            case .denied: "denied"
            case .notYetRequested: "not asked yet"
            case .notRequired: "not requested"
            case .unknown: "unknown"
            }
        }

        /// Borrows the key palette so the status strip reads with the same
        /// vocabulary as the panel. `notInstalled` wears the `needsInput` amber on
        /// purpose: that is the exact key it disables.
        public var swatchState: AgentState {
            switch self {
            case .installed, .granted: .complete
            case .denied: .error
            case .notInstalled: .needsInput
            case .notYetRequested, .unknown: .unknown
            case .notRequired: .unassigned
            }
        }
    }

    public struct Status: Sendable, Equatable {
        public var hooks: Grant
        public var automation: Grant
        /// `nil` until something has actually looked. Rendered as such — an
        /// unchecked status must not look like a fresh one.
        public var checkedAt: Date?

        public init(hooks: Grant, automation: Grant, checkedAt: Date?) {
            self.hooks = hooks
            self.automation = automation
            self.checkedAt = checkedAt
        }

        public static let unchecked = Status(
            hooks: .unknown, automation: .notYetRequested, checkedAt: nil
        )
    }

    public struct StatusRow: Sendable, Equatable, Identifiable {
        public let step: Step
        public let grant: Grant
        public let detail: String
        public var id: String { step.rawValue }
    }

    // MARK: - Actions
    //
    // Every side effect leaves through here, so "does this view touch TCC on
    // appearance?" is answerable by reading one type instead of the whole file.

    /// Injected so the view itself performs nothing. The default is `.inert`,
    /// which is what makes a preview safe: a preview that raised the Automation
    /// prompt would write a decision the user never agreed to and we cannot undo.
    /// `@MainActor` because every member is already a main-actor closure and the
    /// two static presets below are globals of this type — Swift 6 rejects a
    /// non-Sendable global otherwise. Isolating the struct is the honest fix here:
    /// these actions touch AppKit and the user's config, so they belong on the
    /// main actor rather than being made Sendable to satisfy the checker.
    @MainActor
    public struct Actions {
        /// Computes the change without making it. May throw — a settings file with
        /// comments is refused rather than rewritten.
        public var plan: @MainActor (ClaudeHookInstaller.Action) throws -> ClaudeHookInstaller.Plan
        /// The only path that writes the user's config.
        public var apply: @MainActor (ClaudeHookInstaller.Plan) throws -> Void
        /// Re-reads what is knowable. Cheap, no prompts, no Apple Events.
        public var recheck: @MainActor () -> Status
        /// The one call that can raise the Automation dialog. Button-only, never
        /// on appear.
        public var enableFocus: @MainActor () -> Void
        public var declineHooks: @MainActor () -> Void
        /// "Bind a key now" — close this and get on with it.
        public var finish: @MainActor () -> Void

        public init(
            plan: @escaping @MainActor (ClaudeHookInstaller.Action) throws -> ClaudeHookInstaller.Plan,
            apply: @escaping @MainActor (ClaudeHookInstaller.Plan) throws -> Void,
            recheck: @escaping @MainActor () -> Status,
            enableFocus: @escaping @MainActor () -> Void,
            declineHooks: @escaping @MainActor () -> Void = {},
            finish: @escaping @MainActor () -> Void = {}
        ) {
            self.plan = plan
            self.apply = apply
            self.recheck = recheck
            self.enableFocus = enableFocus
            self.declineHooks = declineHooks
            self.finish = finish
        }

        /// Real behaviour. `recheck` deliberately reports Automation as
        /// `notYetRequested`: TCC is not readable from here (Full Disk Access is
        /// denied on this machine) and the only way to learn the answer is to send
        /// an Apple Event, which *is* the prompt. A caller that has already
        /// performed a focus and holds a `FocusOutcome` knows better, and should
        /// replace `recheck` with one that reports `.granted` or `.denied`.
        public static let live = Actions(
            plan: { action in
                ProbeLog.record("plan(\(action))")
                return try ClaudeHookInstaller.plan(action)
            },
            apply: { plan in
                ProbeLog.record("apply(\(plan.action))")
                try ClaudeHookInstaller.apply(plan)
            },
            recheck: {
                ProbeLog.record("recheck")
                return liveStatus()
            },
            enableFocus: {
                ProbeLog.record("warmUp")
                // Off the main actor: a cold Apple Events bridge costs 1.0–2.3 s
                // and this is a click handler.
                Task.detached(priority: .userInitiated) { FocusResolver.warmUp() }
            }
        )

        /// Previews and tests. Does nothing and records nothing, so a preview
        /// cannot write a TCC decision or edit anybody's settings file.
        public static let inert = Actions(
            plan: { _ in throw InertError.previewHasNoSettingsFile },
            apply: { _ in },
            recheck: { .unchecked },
            enableFocus: {}
        )

        enum InertError: Error, CustomStringConvertible {
            case previewHasNoSettingsFile
            public var description: String {
                "this is a preview — no settings file was read and nothing can be written"
            }
        }
    }

    /// Records every real probe. The point is negative evidence: an onboarding
    /// screen that trips a permission decision merely by appearing is a bug that
    /// cannot be undone afterwards, so `selfCheckFailures()` constructs the view
    /// and asserts this stayed empty.
    @MainActor
    public enum ProbeLog {
        public private(set) static var entries: [String] = []
        public static func record(_ name: String) { entries.append(name) }
        public static func reset() { entries.removeAll() }
    }

    /// Hook state is answerable without any permission: plan an install and see
    /// whether it would change anything.
    @MainActor
    static func liveStatus(now: Date = Date()) -> Status {
        ProbeLog.record("liveStatus")
        let hooks: Grant
        do {
            hooks = try ClaudeHookInstaller.plan(.install).isNoOp ? .installed : .notInstalled
        } catch {
            hooks = .unknown
        }
        return Status(hooks: hooks, automation: .notYetRequested, checkedAt: now)
    }

    // MARK: - Copy
    //
    // Every sentence the user reads is produced by a static function so the
    // self-check can assert on the wording. A boolean "warns about needsInput"
    // would pass with an empty string, which is the failure mode this whole
    // screen exists to avoid.

    public static let headline = "What this app needs, and what it costs to say no"

    public static let subhead = """
        Nothing on this screen is required to bind your first key, and nothing \
        here is done without you pressing something. Each item says what breaks \
        if you skip it, in the terms it will actually break in.
        """

    public static func title(_ step: Step) -> String {
        switch step {
        case .hooks: "See when an agent is waiting for you"
        case .automation: "Bring a session's terminal to the front"
        case .accessibility: "Accessibility: not required, and never requested"
        case .microphone: "Microphone: not requested, key disabled"
        }
    }

    /// What we want and why. Non-empty for every step.
    public static func rationale(_ step: Step) -> String {
        switch step {
        case .hooks:
            """
            Claude Code can push a PermissionRequest event the instant it opens a \
            permission prompt — measured at 1 ms, and it fires whether or not you \
            are at the keyboard. That event is the only thing that can turn a key \
            amber. Receiving it means adding this app's forwarder to the hooks \
            section of ~/.claude/settings.json, which is your live Claude Code \
            config. The exact change is below; nothing is written until you press \
            Install hooks.
            """
        case .automation:
            """
            Clicking an agent key raises the terminal that session is running in. \
            macOS classes one app scripting another as Automation and asks once per \
            target app, the first time we send that app an Apple Event. No event is \
            sent until you press Enable focus, and we only ever talk to apps that \
            are already running.
            """
        case .accessibility:
            """
            Accessibility is not required by this app and is never requested. It is \
            listed here because you might expect it: apps that type into other \
            people's windows need it, and this one does not. Focus goes through \
            Automation and NSRunningApplication, and keystrokes only ever go into \
            sessions this app spawned itself, over a pseudo-terminal it owns.
            """
        case .microphone:
            """
            Push-to-talk is deferred, so the microphone is never requested and the \
            talk key ships visibly disabled. Nothing on this panel records audio.
            """
        }
    }

    /// What breaks if this step is skipped. Non-empty for every step, including
    /// the two where the honest answer is "nothing".
    public static func consequence(_ step: Step) -> String {
        switch step {
        case .hooks: declineHooksConsequence
        case .automation:
            """
            Without Automation, click-to-focus does nothing. The key still shows \
            state correctly, but no window comes forward, and a denial arrives as \
            error -1743 rather than as a second dialog. You would go back to \
            hunting for the right terminal window yourself.
            """
        case .accessibility:
            """
            Nothing breaks. No feature depends on it. If a later version ever needs \
            it, that version will ask on its own screen and probe at runtime, \
            because a denial here arrives as a bare error code with no dialog at \
            all — from a command-line context you are never asked and the feature \
            simply fails.
            """
        case .microphone:
            """
            Nothing breaks. The talk key stays disabled whether or not the \
            microphone is allowed, so switching it on in System Settings will not \
            turn the feature on.
            """
        }
    }

    /// The most important string in this file, and the reason the flow exists.
    ///
    /// Wording is deliberate on three points. It names `needsInput`, because that
    /// is the state the product is built on. It says the amber key will *never*
    /// light rather than "may be delayed", because the limit is structural: a
    /// pending permission prompt writes no transcript record at all, so a
    /// permission prompt open for 145 minutes and a Bash call running for 100
    /// minutes produce byte-identical files. And it states the wrong conclusion
    /// out loud, because "the key is calm, so nothing is blocked" is the inference
    /// a person makes by default and it is the one that costs them an hour.
    public static let declineHooksConsequence = """
        Declining leaves needsInput unobservable. A pending permission prompt \
        writes no transcript record at all — nothing is written between a tool_use \
        and its tool_result — so nothing on disk can reveal that an agent is \
        blocked, and the amber key will never light. The other five states still \
        arrive from transcript tailing and click-to-focus is unaffected. What you \
        lose is the one the panel was built for: a calm key will not mean the agent \
        is unblocked, only that this app cannot see.
        """

    /// A second paragraph where one is genuinely load-bearing. `nil` where it is
    /// not, rather than filler.
    public static func note(_ step: Step) -> String? {
        switch step {
        case .hooks:
            """
            Your existing hooks are appended to, never replaced — the entry goes \
            after whatever you already have under each event, and both keep firing. \
            Every entry is a command hook with async: true, so a slow or absent \
            panel cannot delay your sessions.
            """
        case .automation:
            // The Tier 1 / Tier 2 split, stated as the normal case rather than an
            // edge case: 0 of 4 live sessions on this machine are Tier 1.
            """
            What focus can do depends on your terminal. Terminal.app, iTerm2, and \
            tmux hosted in either expose a tty-to-window map, so the window is \
            raised and the tab selected. cmux, GoLand, VS Code and Zed expose no \
            such map: we raise the app and cannot target the tab. All four Claude \
            sessions running on this machine are in that second group, so app-only \
            is the ordinary case here rather than an edge case. Each key says which \
            one it is before you click it.
            """
        case .accessibility, .microphone:
            nil
        }
    }

    /// The escape hatch, and what is left working after taking it. Every step has
    /// one; a step you cannot skip would make this screen a gate.
    public static func skip(_ step: Step) -> String {
        switch step {
        case .hooks:
            """
            Continue without hooks: five of the six states still come from \
            transcript tailing, focus is unaffected, and every key that cannot \
            report needsInput says so in its own detail popover instead of looking \
            calm. Install later from this screen at any time.
            """
        case .automation:
            """
            Skip Automation: all six keys still show state, and the focus action \
            reports that it cannot raise anything rather than failing quietly. \
            Enable it later from this screen.
            """
        case .accessibility:
            "Nothing to skip. Leave it switched off."
        case .microphone:
            "Nothing to skip. The key is disabled either way."
        }
    }

    public static func skipLabel(_ step: Step) -> String? {
        switch step {
        case .hooks: "Continue without hooks"
        case .automation: "Skip focus for now"
        case .accessibility, .microphone: nil
        }
    }

    // MARK: - Hook plan copy

    /// The diff, verbatim from the plan. Deliberately not prose: a description of
    /// an edit to somebody's config is not consent to make it.
    public static func diffText(_ plan: ClaudeHookInstaller.Plan) -> String { plan.diff }

    public static func diffCaption(_ plan: ClaudeHookInstaller.Plan) -> String {
        if plan.isNoOp {
            return plan.action == .install
                ? "Already installed. There is nothing to write — the forwarder is already registered for all \(plan.events.count) events."
                : "Nothing to remove. This app has no entries in that file."
        }
        let path = (plan.settingsURL.path as NSString).abbreviatingWithTildeInPath
        return plan.action == .install
            ? "The change to \(path), line for line, against the file as it is right now:"
            : "Removing this app's entries from \(path):"
    }

    /// Shown whenever `reformatsFile` is set. The user's formatting changing under
    /// them is the kind of surprise that reads as damage, so it is stated before
    /// the write, not discovered in their next `git diff`.
    public static func reformatWarning(_ plan: ClaudeHookInstaller.Plan) -> String? {
        guard plan.reformatsFile else { return nil }
        let backup = (plan.backupURL.path as NSString).abbreviatingWithTildeInPath
        return """
            Applying this re-serializes the whole file in canonical form: keys \
            sorted, indentation normalised, a trailing comma dropped if you have \
            one. Claude Code reads the result identically, but your formatting will \
            change and a diff tool will show the entire file rather than these \
            lines. The current file is copied to \(backup) first.
            """
    }

    public static let commentRefusalNote = """
        A settings file containing comments is refused, not rewritten. Claude Code \
        reads its config as JSONC and this app does not, so rewriting one would \
        silently delete your comments — the installer stops and says so instead.
        """

    public static func planFailure(_ error: Error) -> String {
        """
        Cannot prepare the change: \(error). Nothing was read past that point and \
        nothing will be written. Fix or move the file and press Check again, or \
        continue without hooks — what that costs is below.
        """
    }

    // MARK: - Status copy

    public static let revocationNote = """
        You can revoke any of this later in System Settings, and nothing tells this \
        app when you do. Press Check again after changing anything there. Until \
        then the panel reports what it last saw, and any key it cannot verify goes \
        to unknown rather than keeping the colour it used to have.
        """

    public static func statusDetail(_ step: Step, _ status: Status) -> String {
        switch step {
        case .hooks:
            switch status.hooks {
            case .installed: "Registered in your settings. needsInput can light."
            case .notInstalled: "Not registered. The amber key cannot light for observed sessions."
            default: "Could not read your settings file, so this is unknown rather than assumed."
            }
        case .automation:
            switch status.automation {
            case .granted: "Granted. Focus works as far as your terminal allows."
            case .denied: "Denied — clicking a key raises nothing until you allow it under System Settings, Privacy & Security, Automation."
            default: "macOS has not been asked. It will ask once per terminal app, the first time you use focus."
            }
        case .accessibility: "Never requested by this app. Nothing here needs it."
        case .microphone: "Never requested. The talk key is disabled until push-to-talk ships."
        }
    }

    public static func statusRows(_ status: Status) -> [StatusRow] {
        Step.allCases.map { step in
            let grant: Grant = switch step {
            case .hooks: status.hooks
            case .automation: status.automation
            case .accessibility, .microphone: .notRequired
            }
            return StatusRow(step: step, grant: grant, detail: statusDetail(step, status))
        }
    }

    public static func checkedLine(_ status: Status, now: Date) -> String {
        guard let checkedAt = status.checkedAt else {
            return "Not checked yet."
        }
        let seconds = Int(max(0, now.timeIntervalSince(checkedAt)).rounded())
        let elapsed = seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
        return "Last checked \(elapsed) ago, at \(checkedAt.formatted(date: .omitted, time: .standard))."
    }

    // MARK: - Accessibility

    /// One paragraph per step for VoiceOver, carrying the same sentences in the
    /// same order as the visible card. This screen is where a user learns what the
    /// app can and cannot see, so a screen-reader user needs every word of it —
    /// which is why both texts are built from the same functions rather than
    /// written twice.
    public static func stepSummary(_ step: Step) -> String {
        var parts = [title(step), rationale(step), "If you skip this: " + consequence(step)]
        if let note = note(step) { parts.append(note) }
        parts.append(skip(step))
        return parts.joined(separator: " ")
    }

    public static func statusSummary(_ status: Status, now: Date) -> String {
        let rows = statusRows(status).map { row in
            "\(title(row.step)): \(row.grant.label). \(row.detail)"
        }
        return (["Permission status."] + rows + [checkedLine(status, now: now), revocationNote])
            .joined(separator: " ")
    }

    /// Reduce Motion: status changes snap. A permission flipping colour is
    /// information, not decoration.
    public static func contentTransition(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.15)
    }

    // MARK: - View

    private let layout: PanelLayout
    private let actions: Actions

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var status: Status = .unchecked
    /// `nil` until something has looked. Loaded in `.task`, which is a file read
    /// and nothing else — no Apple Event, no TCC decision.
    @State private var planResult: Result<ClaudeHookInstaller.Plan, Error>?
    @State private var applyError: String?
    @State private var now = Date()

    /// `actions` defaults to `.inert` so the safe thing is the thing you get by
    /// forgetting. Pass `.live` explicitly.
    public init(layout: PanelLayout = .regular, actions: Actions = .inert) {
        self.layout = layout
        self.actions = actions
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                statusStrip
                ForEach(Step.allCases) { card($0) }
            }
            .padding(20)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .background(surface)
        .animation(Self.contentTransition(reduceMotion: reduceMotion), value: status)
        .task {
            // Cheap and permission-free: reads our own spool and the user's
            // settings file. Deliberately does NOT call enableFocus.
            status = actions.recheck()
            now = Date()
            reloadPlan(.install)
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.headline)
                .font(.system(size: layout.fontSize(17), weight: .semibold))
            Text(Self.subhead)
                .font(.system(size: layout.fontSize(11)))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Bind a key now", action: actions.finish)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint("Closes this screen. You can come back to it from the panel menu.")
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Status

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Current status")
                Spacer(minLength: 8)
                Button("Check again") {
                    status = actions.recheck()
                    now = Date()
                    reloadPlan(.install)
                }
                .font(.system(size: layout.fontSize(11)))
                .accessibilityHint("Re-reads what is knowable without asking macOS for anything.")
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Self.statusRows(status)) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        chip(row.grant)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.title(row.step))
                                .font(.system(size: layout.fontSize(11), weight: .medium))
                            Text(row.detail)
                                .font(.system(size: layout.fontSize(10)))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text(Self.checkedLine(status, now: now))
                    .font(.system(size: layout.fontSize(10)))
                    .foregroundStyle(.tertiary)
                Text(Self.revocationNote)
                    .font(.system(size: layout.fontSize(10)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // One VoiceOver element for the whole read-only strip: a coherent
            // paragraph beats eight unlabelled fragments. The button above stays
            // separately focusable.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.statusSummary(status, now: now))
        }
        .padding(12)
        .background(panel)
    }

    private func chip(_ grant: Grant) -> some View {
        let s = swatch(grant.swatchState)
        return Text(grant.label)
            .font(.system(size: layout.fontSize(9), weight: .semibold))
            .foregroundStyle(s.keyLabel.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(
                s.keyFill.color.opacity(reduceTransparency ? 1 : s.fillOpacity)
            ))
            .overlay(Capsule().strokeBorder(
                s.keyEdge.color.opacity(0.6), lineWidth: reduceTransparency ? 1.5 : 0.5
            ))
            .frame(minWidth: 84, alignment: .leading)
    }

    // MARK: Cards

    private func card(_ step: Step) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.title(step))
                .font(.system(size: layout.fontSize(13), weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                paragraph(Self.rationale(step))
                consequenceBox(step)
                if let note = Self.note(step) {
                    paragraph(note).foregroundStyle(.secondary)
                }
                paragraph(Self.skip(step)).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.stepSummary(step))

            if step == .hooks { hookPlanSection }
            actionRow(step)
        }
        .padding(12)
        .background(panel)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.system(size: layout.fontSize(11)))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The consequence wears the colour of the key it affects — amber for the
    /// hooks decline, since that is literally the key that stops working, and the
    /// neutral `unknown` grey where nothing breaks.
    private func consequenceBox(_ step: Step) -> some View {
        let state: AgentState = switch step {
        case .hooks: .needsInput
        case .automation: .unknown
        case .accessibility, .microphone: .unassigned
        }
        let s = swatch(state)
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: step.isRequested ? "exclamationmark.triangle" : "info.circle")
                .font(.system(size: layout.fontSize(10), weight: .bold))
            Text(Self.consequence(step))
                .font(.system(size: layout.fontSize(10), weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(s.keyLabel.color)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(s.keyFill.color.opacity(reduceTransparency ? 1 : s.fillOpacity)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(s.keyEdge.color.opacity(0.7),
                          lineWidth: reduceTransparency ? 1.5 : 0.5))
    }

    // MARK: The diff

    private var hookPlanSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch planResult {
            case nil:
                Text("Reading your settings file…")
                    .font(.system(size: layout.fontSize(10)))
                    .foregroundStyle(.secondary)
            case .failure(let error):
                Text(Self.planFailure(error))
                    .font(.system(size: layout.fontSize(10), weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            case .success(let plan):
                Text(Self.diffCaption(plan))
                    .font(.system(size: layout.fontSize(10)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !plan.isNoOp {
                    diffBox(plan)
                }
                if let warning = Self.reformatWarning(plan) {
                    paragraph(warning).font(.system(size: layout.fontSize(10), weight: .medium))
                }
            }
            paragraph(Self.commentRefusalNote)
                .font(.system(size: layout.fontSize(10)))
                .foregroundStyle(.secondary)
            if let applyError {
                Text(applyError)
                    .font(.system(size: layout.fontSize(10), weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// `.focusable()` so a keyboard-only user can Tab to the diff and scroll it
    /// with the arrow keys. Selectable so it can be copied into a review.
    private func diffBox(_ plan: ClaudeHookInstaller.Plan) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(Self.diffText(plan))
                .font(.system(size: layout.fontSize(10), design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 220)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(.quaternary, lineWidth: reduceTransparency ? 1.5 : 0.5))
        .focusable()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Proposed change to \((plan.settingsURL.path as NSString).abbreviatingWithTildeInPath), "
            + "as a line diff. \(Self.diffText(plan))"
        )
    }

    // MARK: Actions

    @ViewBuilder
    private func actionRow(_ step: Step) -> some View {
        switch step {
        case .hooks:
            HStack(spacing: 8) {
                Button("Install hooks") { applyPlan() }
                    .disabled(!canInstall)
                    .accessibilityHint("Writes the change shown above, after backing the file up.")
                Button("Remove hooks") { removeHooks() }
                    .disabled(status.hooks != .installed)
                    .accessibilityHint("Deletes this app's entries and its forwarder script, and nothing else.")
                Spacer(minLength: 0)
                if let label = Self.skipLabel(step) {
                    Button(label, action: actions.declineHooks)
                }
            }
            .font(.system(size: layout.fontSize(11)))
        case .automation:
            HStack(spacing: 8) {
                Button("Enable focus") { actions.enableFocus() }
                    .accessibilityHint("Sends one harmless Apple Event, which is what makes macOS ask. Nothing happens until you press this.")
                Spacer(minLength: 0)
                if let label = Self.skipLabel(step) {
                    Button(label) {}
                        .accessibilityHint("Leaves Automation unasked. Focus reports that it cannot raise anything.")
                }
            }
            .font(.system(size: layout.fontSize(11)))
        case .accessibility, .microphone:
            EmptyView()
        }
    }

    private var canInstall: Bool {
        if case .success(let plan) = planResult { return !plan.isNoOp && plan.action == .install }
        return false
    }

    private func reloadPlan(_ action: ClaudeHookInstaller.Action) {
        planResult = Result { try actions.plan(action) }
    }

    private func applyPlan() {
        guard case .success(let plan) = planResult else { return }
        do {
            try actions.apply(plan)
            applyError = nil
        } catch {
            applyError = "The write failed: \(error). Your settings file is unchanged, "
                + "or restorable from \((plan.backupURL.path as NSString).abbreviatingWithTildeInPath)."
        }
        status = actions.recheck()
        now = Date()
        reloadPlan(.install)
    }

    /// One press: plan and apply. Removal only ever deletes entries this app
    /// added, so there is nothing for the user to weigh up first.
    private func removeHooks() {
        do {
            try actions.apply(try actions.plan(.uninstall))
            applyError = nil
        } catch {
            applyError = "Could not remove the hooks: \(error). Your settings file is unchanged."
        }
        status = actions.recheck()
        now = Date()
        reloadPlan(.install)
    }

    // MARK: Chrome

    private var appearance: StateColors.Appearance {
        AgentKeyView.appearance(
            colorScheme: colorScheme, increasedContrast: colorSchemeContrast == .increased
        )
    }

    private func swatch(_ state: AgentState) -> StateColors.StateSwatch {
        StateColors.swatch(for: state, in: appearance)
    }

    private var surface: some View {
        Color(nsColor: .windowBackgroundColor)
    }

    /// Reduce Transparency: opaque fill and an edge you can actually find,
    /// matching the correction the a11y audit forced on the other panel views.
    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            shape.fill(reduceTransparency
                ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                : AnyShapeStyle(.ultraThinMaterial))
            shape.strokeBorder(.quaternary, lineWidth: reduceTransparency ? 1.5 : 0.5)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: layout.fontSize(9), weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Self check

extension OnboardingView {
    /// Empty when healthy. Wire into `SelfCheck.run()` with:
    ///
    ///     failures += OnboardingView.selfCheckFailures().map { "onboarding: \($0)" }
    ///
    /// Asserts on the strings a user reads, and on the absence of side effects.
    /// The side-effect check is the one that matters most: a screen that trips a
    /// TCC decision on appearance writes a permanent answer to a question the
    /// user was never asked, and no later code can take it back.
    @MainActor
    public static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // 1. Declining hooks must name the real consequence. Asserted against the
        //    wording, not a flag.
        let decline = declineHooksConsequence
        check("the decline-hooks text does not name needsInput", decline.contains("needsInput"))
        check("the decline-hooks text does not say the amber key will never light",
              decline.contains("the amber key will never light"))
        check("the decline-hooks text does not explain why (no transcript record)",
              decline.contains("no transcript record"))
        check("the decline-hooks text does not correct the calm-key inference",
              decline.lowercased().contains("calm key"))
        check("the hooks step's consequence is not the decline text",
              consequence(.hooks) == decline)
        // "Reduced functionality" is the euphemism this screen exists to avoid.
        check("the decline-hooks text hides behind 'reduced functionality'",
              !decline.lowercased().contains("reduced functionality"))

        // 2. Every step explains itself, costs something specific, and can be
        //    skipped without dead-ending.
        for step in Step.allCases {
            check("step \(step.rawValue) has no title", !title(step).isEmpty)
            check("step \(step.rawValue) has no rationale", !rationale(step).isEmpty)
            check("step \(step.rawValue) has no consequence of skipping",
                  !consequence(step).isEmpty)
            check("step \(step.rawValue) has no skip", !skip(step).isEmpty)
            let summary = stepSummary(step)
            check("step \(step.rawValue) summary drops its rationale",
                  summary.contains(rationale(step)))
            check("step \(step.rawValue) summary drops its consequence",
                  summary.contains(consequence(step)))
            check("step \(step.rawValue) summary drops its skip", summary.contains(skip(step)))
            if let note = note(step) {
                check("step \(step.rawValue) summary drops its note", summary.contains(note))
            }
        }
        check("a requested step has no button label",
              Step.allCases.filter(\.isRequested).allSatisfy { skipLabel($0) != nil })

        // 3. Automation must state the app-only limitation. On this machine all
        //    four live sessions are Tier 2, so this is the ordinary case.
        let automation = stepSummary(.automation)
        check("the Automation copy does not mention the app-only tier limit",
              automation.contains("cannot target the tab"))
        check("the Automation copy does not say app-only is the normal case here",
              automation.lowercased().contains("app-only is the ordinary case"))
        check("the Automation copy does not say the prompt is per target app",
              automation.lowercased().contains("once per target app"))
        check("the Automation consequence does not name the denial code",
              consequence(.automation).contains("-1743"))

        // 4. Accessibility must never be described as required, on any step.
        for step in Step.allCases {
            let text = stepSummary(step).lowercased()
            for claim in ["accessibility is required", "requires accessibility",
                          "needs accessibility", "grant accessibility",
                          "enable accessibility"] where text.contains(claim) {
                failures.append("step \(step.rawValue) claims Accessibility is required: '\(claim)'")
            }
        }
        check("the Accessibility step does not say it is not required",
              rationale(.accessibility).contains("not required"))
        check("the Accessibility step does not say it is never requested",
              rationale(.accessibility).contains("never requested"))
        check("the Accessibility step does not explain the silent denial",
              consequence(.accessibility).contains("no dialog"))
        check("Accessibility is a step the user is asked to grant",
              !Step.accessibility.isRequested)
        // The microphone key ships disabled; the copy must not imply otherwise.
        check("the microphone step implies push-to-talk works",
              rationale(.microphone).contains("disabled"))
        check("Microphone is a step the user is asked to grant", !Step.microphone.isRequested)

        // 5. Constructing the view must perform nothing. This is the check the
        //    whole ProbeLog exists for: an onboarding screen that raises the
        //    Automation prompt on appearance writes a permanent TCC decision, and
        //    that is not a bug you can fix in the next release.
        ProbeLog.reset()
        var counted = Actions.inert
        counted.plan = { action in
            ProbeLog.record("plan(\(action))")
            throw Actions.InertError.previewHasNoSettingsFile
        }
        counted.apply = { _ in ProbeLog.record("apply") }
        counted.recheck = { ProbeLog.record("recheck"); return .unchecked }
        counted.enableFocus = { ProbeLog.record("warmUp") }
        _ = OnboardingView(actions: counted)
        _ = OnboardingView(layout: .compact, actions: counted)
        _ = OnboardingView(layout: .regular, actions: .live)
        // And every piece of copy, since a probe hidden in a text helper is the
        // subtle version of the same bug.
        for step in Step.allCases {
            _ = stepSummary(step)
            _ = skipLabel(step)
        }
        _ = statusRows(.unchecked)
        _ = statusSummary(.unchecked, now: Date())
        _ = checkedLine(.unchecked, now: Date())
        if !ProbeLog.entries.isEmpty {
            failures.append(
                "constructing the view probed the system: \(ProbeLog.entries.joined(separator: ", "))"
            )
        }
        // The default must be the safe one: `.inert` reaches nothing at all.
        Actions.inert.enableFocus()
        _ = Actions.inert.recheck()
        Actions.inert.declineHooks()
        Actions.inert.finish()
        if !ProbeLog.entries.isEmpty {
            failures.append("the inert actions used for previews are not inert: \(ProbeLog.entries)")
        }
        ProbeLog.reset()

        // 6. The consent surface shows the plan's own diff rather than a
        //    paraphrase of it, and warns about the re-serialization.
        let fixture = ClaudeHookInstaller.Plan(
            action: .install,
            settingsURL: URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json"),
            backupURL: URL(fileURLWithPath: NSHomeDirectory() + "/.claude/settings.json.vcm-backup"),
            forwarderURL: URL(fileURLWithPath: "/tmp/claude-hook.sh"),
            spoolDirectory: URL(fileURLWithPath: "/tmp/spool"),
            events: ClaudeHookInstaller.subscribedEvents,
            diff: "  {\n+   \"hooks\": {}\n  }",
            isNoOp: false,
            reformatsFile: true,
            newContents: Data()
        )
        check("the diff shown is not the plan's own diff", diffText(fixture) == fixture.diff)
        check("the diff caption is empty", !diffCaption(fixture).isEmpty)
        check("the diff caption hides the file being edited",
              diffCaption(fixture).contains("~/.claude/settings.json"))
        guard let reformat = reformatWarning(fixture) else {
            return failures + ["a reformatting plan produced no warning"]
        }
        check("the reformat warning does not say the file is re-serialized",
              reformat.contains("re-serializes"))
        check("the reformat warning does not mention the backup",
              reformat.contains(".vcm-backup"))

        var quiet = fixture
        quiet = ClaudeHookInstaller.Plan(
            action: fixture.action, settingsURL: fixture.settingsURL, backupURL: fixture.backupURL,
            forwarderURL: fixture.forwarderURL, spoolDirectory: fixture.spoolDirectory,
            events: fixture.events, diff: "", isNoOp: true, reformatsFile: false,
            newContents: Data()
        )
        check("a no-op plan still warns about reformatting", reformatWarning(quiet) == nil)
        check("a no-op plan does not say it is already installed",
              diffCaption(quiet).lowercased().contains("already installed"))
        check("the comment-refusal note does not say a comment file is refused",
              commentRefusalNote.contains("refused"))
        check("the comment-refusal note does not say comments are not stripped",
              commentRefusalNote.lowercased().contains("silently delete"))
        check("the plan failure text does not say nothing was written",
              planFailure(Actions.InertError.previewHasNoSettingsFile)
                  .contains("nothing will be written"))

        // 7. The status view has a row per step, a label per grant, and says that
        //    a revoked permission will not announce itself.
        let rows = statusRows(Status(hooks: .installed, automation: .granted, checkedAt: Date()))
        check("the status view is missing a row", rows.count == Step.allCases.count)
        for row in rows {
            check("status row \(row.step.rawValue) has no detail", !row.detail.isEmpty)
        }
        for grant in Grant.allCases {
            check("grant \(grant.rawValue) has no label", !grant.label.isEmpty)
        }
        check("granted and denied share a colour",
              Grant.granted.swatchState != Grant.denied.swatchState)
        check("uninstalled hooks do not wear the amber key's colour",
              Grant.notInstalled.swatchState == .needsInput)
        check("'not asked' and 'granted' share a colour",
              Grant.notYetRequested.swatchState != Grant.granted.swatchState)
        check("the status view does not mention revocation", revocationNote.contains("revoke"))
        check("the status view does not tell the user to re-check",
              revocationNote.contains("Check again"))
        check("an unchecked status claims to be fresh",
              checkedLine(.unchecked, now: Date()).contains("Not checked yet"))
        let checked = Status(hooks: .installed, automation: .granted,
                             checkedAt: Date(timeIntervalSince1970: 1_800_000_000))
        check("a checked status does not report when",
              checkedLine(checked, now: Date(timeIntervalSince1970: 1_800_000_090))
                  .contains("1m ago"))
        // Both installed and not-installed must reach VoiceOver, and read
        // differently — the whole point of the strip.
        let announced = statusSummary(
            Status(hooks: .notInstalled, automation: .denied, checkedAt: Date()), now: Date()
        )
        check("the status summary omits the amber-key consequence",
              announced.contains("The amber key cannot light"))
        check("installed and not-installed statuses read alike",
              statusSummary(Status(hooks: .installed, automation: .granted, checkedAt: Date()),
                            now: Date()) != announced)

        // 8. Reduce Motion snaps, and nothing routes around the 9pt floor.
        check("Reduce Motion still animates the status strip",
              contentTransition(reduceMotion: true) == nil)
        check("the status strip does not animate when motion is allowed",
              contentTransition(reduceMotion: false) != nil)
        for base in [9, 10, 11, 13, 17] as [CGFloat]
        where PanelLayout.compact.fontSize(base) < PanelLayout.minimumFontSize {
            failures.append("base \(base)pt resolves under the \(PanelLayout.minimumFontSize)pt floor")
        }

        return failures
    }
}
