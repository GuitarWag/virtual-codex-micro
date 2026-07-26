import Foundation
import SwiftUI

/// The detail the panel deliberately does not show. Hover or secondary-click an
/// agent key and this is what appears: identity, capability, and the three things
/// the M0 spikes made non-optional.
///
/// The panel stays a macro pad — six keys, a colour, a word. Everything that
/// would turn it into a dashboard lives here, one gesture away. What this view is
/// *for*, beyond name and branch:
///
/// 1. **Provenance.** A `running` pushed by a hook and a `running` guessed from a
///    transcript tail are the same colour and are not the same claim. The user
///    must be able to tell which one they are looking at, or the panel is pretty
///    rather than trustworthy.
/// 2. **The blind spot, said out loud.** `Resolution.unobservable` is the engine
///    admitting what its live sources cannot see. When `needsInput` is in there,
///    transcript tailing physically cannot detect a pending permission prompt —
///    nothing is written between a `tool_use` and its `tool_result` — so the amber
///    key can never light. A user who does not know that reads a calm key as "not
///    blocked". This is the most important text in the app.
/// 3. **Focus tier.** What clicking will actually do, per `FocusTier`. On the
///    development machine 0 of 4 live sessions are Tier 1, so "raises the app but
///    cannot target the tab" is the common case, not an edge case.
///
/// Only `needsInput` gets a blind-spot callout even though `unobservable` may hold
/// more. The other members are artefacts of which bookkeeping source happens to be
/// fresh (`unassigned` comes from our own slot table) and mean nothing to a person;
/// `needsInput` is the one whose absence changes what the user should believe.
///
/// Colours come from `StateColors`, sizes from `PanelLayout.fontSize(_:)`. Nothing
/// here invents either. Reduce Transparency drops the material for a solid fill
/// and a thicker edge — the same correction `DialView` and `DirectionPadView`
/// needed after the a11y audit, applied here from the start.
public struct SessionPopover: View {

    // MARK: - Input

    /// Everything the popover renders. `session == nil` means the slot is empty,
    /// which is a different fact from `resolution.state == .unknown` and gets a
    /// different body.
    public struct Detail: Sendable {
        public let slotIndex: Int
        public let session: AgentSession?
        /// `AgentBackend.displayName`, resolved by the caller — this view never
        /// branches on which backend it is talking to.
        public let backendName: String
        /// Straight from `StateEngine.resolve`. Carries the reason, the confidence
        /// and the blind spots.
        public let resolution: Resolution
        /// From `FocusResolver.resolve(pid:)`. `nil` when focus has not been
        /// resolved yet, which is honestly reported rather than assumed Tier 1.
        public let focus: FocusPlan?

        public init(
            slotIndex: Int,
            session: AgentSession?,
            backendName: String,
            resolution: Resolution,
            focus: FocusPlan? = nil
        ) {
            self.slotIndex = slotIndex
            self.session = session
            self.backendName = backendName
            self.resolution = resolution
            self.focus = focus
        }

        /// An empty slot is `unassigned` whatever the engine last said about the
        /// session that used to be here.
        public var state: AgentState { session == nil ? .unassigned : resolution.state }

        public var capabilities: SessionCapabilities { session?.capabilities ?? [] }
        public var canFocus: Bool { capabilities.contains(.focus) }
    }

    /// One label/value pair in the detail table.
    public struct Row: Sendable, Equatable, Identifiable {
        public let label: String
        public let value: String
        public var id: String { label }
    }

    // MARK: - Pure text
    //
    // Every string the popover shows is built by a static function so the
    // self-check can assert on the actual wording rather than on a flag. A
    // boolean "warns about needsInput" would pass with an empty string.

    /// Known state sources, named for a human. Raw ids like `claude.transcript`
    /// are honest but read as debug output.
    private static let sourceNames: [String: String] = [
        "claude.hooks": "Claude Code hooks",
        "claude.transcript": "transcript tailing",
        "app.binding": "this app's own slot binding",
        "mock": "the mock backend",
    ]

    /// `Resolution.reason` is documented as `"<sourceID> reported <state>"` for a
    /// resolved reading, and prose otherwise ("no source has reported", "every
    /// source went quiet"). Take the leading token when it looks like a source id;
    /// nil means nobody is currently speaking for this session.
    public static func sourceName(fromReason reason: String) -> String? {
        let token = String(reason.prefix { !$0.isWhitespace })
        if let known = sourceNames[token] { return known }
        return token.contains(".") ? token : nil
    }

    /// Why the key is this colour, in one line. Never empty for any state.
    public static func provenanceLine(state: AgentState, resolution: Resolution) -> String {
        let verb = resolution.confidence == .reported ? "reported by" : "inferred from"
        guard let source = sourceName(fromReason: resolution.reason) else {
            return "\(state.label) — no source is currently reporting on this session"
        }
        return "\(state.label) — \(verb) \(source)"
    }

    /// The distinction the whole provenance section exists for. The two branches
    /// must not read alike: witnessed and probable are different promises.
    public static func confidenceExplanation(
        state: AgentState, confidence: StateConfidence
    ) -> String {
        switch confidence {
        case .reported:
            "A hook pushed this at the moment it happened, so \"\(state.label)\" is witnessed."
        case .inferred:
            "This was read off the transcript on disk rather than pushed by the session, so \"\(state.label)\" is probable, not witnessed."
        }
    }

    /// The single most important string in this view. `nil` when the amber key can
    /// actually light for this session.
    ///
    /// Wording is deliberate on three points: it names *this session* rather than
    /// the app, it says the key will never turn amber rather than "may be delayed",
    /// and it states the wrong conclusion explicitly — a calm key is not evidence
    /// of an unblocked agent — because that is the inference a user makes by
    /// default and it is the one that costs them an hour.
    public static func blindSpotWarning(_ resolution: Resolution) -> String? {
        guard !resolution.needsInputObservable else { return nil }
        return """
            Blind spot: this session cannot report when it is waiting for you. \
            No live source can see a pending permission prompt, so this key will \
            never turn amber — a calm key here does not mean the agent is \
            unblocked. Check the session itself before assuming it is not waiting.
            """
    }

    /// What clicking the key will do. Non-empty for every tier, because a key that
    /// is inert without saying why is the failure the whole focus design avoids.
    ///
    /// `plan.reason` is preferred when present — `FocusResolver` owns that sentence
    /// and names the real host app. The per-tier fallbacks cover the window before
    /// focus has been resolved.
    public static func clickAction(
        tier: FocusTier, plan: FocusPlan? = nil, canFocus: Bool = true
    ) -> String {
        guard canFocus else {
            return "Clicking does nothing: this session does not offer focus."
        }
        if let reason = plan?.reason, !reason.isEmpty { return reason }
        return switch tier {
        case .windowAndTab: "Clicking raises the terminal window and selects this session's tab."
        case .appOnly: "Clicking raises the terminal app only — it cannot target this session's tab."
        case .impossible: "Clicking cannot bring this session on screen."
        }
    }

    /// Which keys can act on this session. Says what is missing as well as what is
    /// present: an observed session's disabled accept key needs an explanation.
    public static func capabilitySummary(_ capabilities: SessionCapabilities) -> String {
        let all: [(SessionCapabilities, String)] = [
            (.focus, "focus"), (.approve, "approve"), (.reject, "reject"),
            (.sendPrompt, "send prompts"), (.setEffort, "set effort"),
        ]
        let have = all.filter { capabilities.contains($0.0) }.map(\.1)
        let missing = all.filter { !capabilities.contains($0.0) }.map(\.1)
        if have.isEmpty { return "nothing — no key can act on this session" }
        if missing.isEmpty { return "everything: " + have.joined(separator: ", ") }
        return have.joined(separator: ", ")
            + " — cannot " + missing.joined(separator: ", ")
    }

    /// "4m 12s ago, at 14:32:07". Coarse on purpose past an hour; nobody reads
    /// seconds off a two-day-old transition.
    public static func transitionLine(_ transition: Date, now: Date) -> String {
        let seconds = Int(max(0, now.timeIntervalSince(transition)).rounded())
        let elapsed: String = if seconds < 60 {
            "\(seconds)s"
        } else if seconds < 3600 {
            "\(seconds / 60)m \(seconds % 60)s"
        } else if seconds < 86_400 {
            "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        } else {
            "\(seconds / 86_400)d"
        }
        return "\(elapsed) ago, at \(transition.formatted(date: .omitted, time: .standard))"
    }

    /// The detail table. A row is *absent* when its fact is absent — no "Branch: —"
    /// placeholder and no empty value, because a bare label reads as a bug and
    /// VoiceOver announces it as one.
    public static func infoRows(
        session: AgentSession?, backendName: String, now: Date
    ) -> [Row] {
        guard let session else { return [] }
        var rows: [Row] = []
        func add(_ label: String, _ value: String?) {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return }
            rows.append(Row(label: label, value: value))
        }
        add("Backend", backendName)
        add("Repo", session.repoPath.map { ($0 as NSString).abbreviatingWithTildeInPath })
        add("Branch", session.branch)
        add("Can do", capabilitySummary(session.capabilities))
        add("Last change", transitionLine(session.lastTransition, now: now))
        return rows
    }

    /// One paragraph for VoiceOver, carrying the same facts in the same order as
    /// the visible layout — including the provenance and the blind-spot warning
    /// verbatim. A screen-reader user needs to know the state is inferred exactly
    /// as much as a sighted one does, so the two texts are built from the same
    /// functions rather than written twice.
    public static func accessibilitySummary(_ detail: Detail, now: Date) -> String {
        /// Sentences that already end in punctuation must not collect a second
        /// full stop: VoiceOver reads ".." as a pause long enough to sound broken.
        func sentences(_ parts: [String]) -> String {
            parts.map { part in
                part.hasSuffix(".") || part.hasSuffix("?") ? part : part + "."
            }
            .joined(separator: " ")
        }

        var parts: [String] = ["Session detail, agent key \(detail.slotIndex + 1)"]
        guard let session = detail.session else {
            parts.append("no session bound")
            return sentences(parts)
        }
        parts.append(session.title)
        parts += infoRows(session: session, backendName: detail.backendName, now: now)
            .map { "\($0.label): \($0.value)" }
        parts.append(provenanceLine(state: detail.state, resolution: detail.resolution))
        parts.append(
            confidenceExplanation(state: detail.state, confidence: detail.resolution.confidence)
        )
        if let warning = blindSpotWarning(detail.resolution) { parts.append(warning) }
        parts.append("Focus: \(focusTier(detail).label)")
        parts.append(
            clickAction(tier: focusTier(detail), plan: detail.focus, canFocus: detail.canFocus)
        )
        return sentences(parts)
    }

    /// No focus plan yet is not Tier 1. Unresolved degrades to the honest floor.
    public static func focusTier(_ detail: Detail) -> FocusTier {
        detail.canFocus ? (detail.focus?.tier ?? .impossible) : .impossible
    }

    /// Reduce Motion: the popover's contents snap. Its own present/dismiss is
    /// AppKit's, but a state change arriving while it is open must not slide.
    public static func contentTransition(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.15)
    }

    // MARK: - View

    private let detail: Detail
    private let layout: PanelLayout
    private let onRebind: () -> Void
    private let onClear: () -> Void
    private let onOpenLog: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Fixed for the popover's lifetime on purpose: a relative timestamp that
    /// re-renders every frame is a distraction, and the popover is short-lived.
    @State private var now = Date()

    /// `onOpenLog` is a closure because the activity log is task 027's. This view
    /// must not know what a log entry is.
    public init(
        detail: Detail,
        layout: PanelLayout = .regular,
        onRebind: @escaping () -> Void = {},
        onClear: @escaping () -> Void = {},
        onOpenLog: @escaping () -> Void = {}
    ) {
        self.detail = detail
        self.layout = layout
        self.onRebind = onRebind
        self.onClear = onClear
        self.onOpenLog = onOpenLog
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            // One a11y element for the whole read-only block: VoiceOver gets a
            // coherent paragraph instead of eleven unlabelled fragments, while the
            // action buttons below stay individually focusable.
            VStack(alignment: .leading, spacing: 10) {
                if detail.session == nil {
                    Text("No session bound. Rebind to point this key at a session.")
                        .font(.system(size: layout.fontSize(11)))
                        .foregroundStyle(.secondary)
                } else {
                    infoTable
                    provenanceSection
                    if let warning = Self.blindSpotWarning(detail.resolution) {
                        warningBox(warning)
                    }
                    focusSection
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.accessibilitySummary(detail, now: now))

            Divider()
            actions
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
        .background(background)
        .animation(Self.contentTransition(reduceMotion: reduceMotion), value: detail.state)
    }

    // MARK: Parts

    private var appearance: StateColors.Appearance {
        AgentKeyView.appearance(
            colorScheme: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private func swatch(_ state: AgentState) -> StateColors.StateSwatch {
        StateColors.swatch(for: state, in: appearance)
    }

    /// Reduce Transparency: opaque surface plus an edge you can actually find.
    /// The popover's own chrome is not a defined edge under that setting.
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            shape.fill(reduceTransparency
                ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                : AnyShapeStyle(.ultraThinMaterial))
            shape.strokeBorder(.quaternary, lineWidth: reduceTransparency ? 1.5 : 0.5)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(detail.session?.title ?? "Slot \(detail.slotIndex + 1)")
                .font(.system(size: layout.fontSize(13), weight: .semibold))
                .lineLimit(2)
            Spacer(minLength: 4)
            stateChip
        }
    }

    /// State as hue *and* word, the same rule the key itself follows.
    private var stateChip: some View {
        let s = swatch(detail.state)
        return Text(detail.state.label)
            .font(.system(size: layout.fontSize(10), weight: .semibold))
            .foregroundStyle(s.keyLabel.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    s.keyFill.color.opacity(reduceTransparency ? 1 : s.fillOpacity)
                )
            )
            .overlay(Capsule().strokeBorder(
                s.keyEdge.color.opacity(0.6),
                lineWidth: reduceTransparency ? 1.5 : 0.5
            ))
    }

    private var infoTable: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
            ForEach(Self.infoRows(
                session: detail.session, backendName: detail.backendName, now: now
            )) { row in
                GridRow {
                    Text(row.label)
                        .font(.system(size: layout.fontSize(10)))
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(row.value)
                        .font(.system(size: layout.fontSize(11)))
                        .textSelection(.enabled)
                }
            }
        }
    }

    private var provenanceSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Why this colour")
            Text(Self.provenanceLine(state: detail.state, resolution: detail.resolution))
                .font(.system(size: layout.fontSize(11), weight: .medium))
            Text(Self.confidenceExplanation(
                state: detail.state, confidence: detail.resolution.confidence
            ))
            .font(.system(size: layout.fontSize(10)))
            .foregroundStyle(.secondary)
        }
    }

    /// Tinted with the `needsInput` swatch on purpose: this box is about the amber
    /// key that will never light, so it wears that key's colour.
    private func warningBox(_ warning: String) -> some View {
        let s = swatch(.needsInput)
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.system(size: layout.fontSize(10), weight: .bold))
            Text(warning)
                .font(.system(size: layout.fontSize(10), weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(s.keyLabel.color)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(s.keyFill.color.opacity(reduceTransparency ? 1 : s.fillOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(s.keyEdge.color.opacity(0.7),
                              lineWidth: reduceTransparency ? 1.5 : 0.5)
        )
    }

    private var focusSection: some View {
        let tier = Self.focusTier(detail)
        return VStack(alignment: .leading, spacing: 2) {
            sectionTitle("Clicking this key")
            Text(Self.clickAction(tier: tier, plan: detail.focus, canFocus: detail.canFocus))
                .font(.system(size: layout.fontSize(11)))
                .fixedSize(horizontal: false, vertical: true)
            Text("Focus tier \(tier.rawValue) — \(tier.label)")
                .font(.system(size: layout.fontSize(10)))
                .foregroundStyle(.secondary)
            if let attach = detail.focus?.attachCommand {
                Text(attach)
                    .font(.system(size: layout.fontSize(10), design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: layout.fontSize(9), weight: .semibold))
            .foregroundStyle(.tertiary)
    }

    /// Plain `Button`s: Tab reaches them, Space and Return fire them, and the
    /// button trait comes free. Nothing here needs a custom control.
    private var actions: some View {
        HStack(spacing: 8) {
            Button("Rebind…", action: onRebind)
                .accessibilityHint("Point this key at a different session.")
            Button("Clear slot", action: onClear)
                .disabled(detail.session == nil)
                .accessibilityHint("Leave this key empty.")
            Spacer(minLength: 0)
            Button("Activity", action: onOpenLog)
                .disabled(detail.session == nil)
                .accessibilityLabel("Open activity log")
                .accessibilityHint("Shows events for this session only.")
        }
        .font(.system(size: layout.fontSize(11)))
    }

    // MARK: - Self check

    /// Asserts on the strings the user actually reads, not on flags: a boolean
    /// "warns about needsInput" would pass with an empty warning. Empty when
    /// healthy. Wire into `SelfCheck.run()` with:
    ///
    ///     failures += SessionPopover.selfCheckFailures().map { "popover: \($0)" }
    public static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let now = t0.addingTimeInterval(252)

        func detail(
            session: AgentSession?, resolution: Resolution, focus: FocusPlan? = nil
        ) -> Detail {
            Detail(slotIndex: 0, session: session, backendName: "Claude Code",
                   resolution: resolution, focus: focus)
        }

        let full = AgentSession(
            id: "s1", backendID: "claude", title: "audit ledger sync",
            repoPath: "/Users/x/work/ledger", branch: "fix/rounding",
            state: .running, confidence: .inferred,
            capabilities: .observed, lastTransition: t0
        )

        // 1. A blind spot must produce a warning the user can read AND one
        //    VoiceOver reads out. Asserted against the real strings.
        let blind = Resolution(
            state: .running, confidence: .inferred, liveness: .alive,
            reason: "claude.transcript reported running",
            unobservable: [.needsInput, .unassigned]
        )
        guard let warning = blindSpotWarning(blind) else {
            return failures + ["a resolution that cannot see needsInput produced no warning"]
        }
        check("blind-spot warning is empty", !warning.isEmpty)
        check("blind-spot warning does not mention waiting",
              warning.lowercased().contains("waiting"))
        check("blind-spot warning does not say the key stays calm",
              warning.lowercased().contains("never turn amber"))
        let blindSummary = accessibilitySummary(detail(session: full, resolution: blind), now: now)
        check("blind-spot warning is visual only — VoiceOver never hears it",
              blindSummary.contains(warning))

        // And the inverse: hooks fresh, no warning anywhere.
        let seeing = Resolution(
            state: .running, confidence: .reported, liveness: .alive,
            reason: "claude.hooks reported running", unobservable: []
        )
        check("a session that can see needsInput still warns", blindSpotWarning(seeing) == nil)
        check("warning leaked into a session with no blind spot",
              !accessibilitySummary(detail(session: full, resolution: seeing), now: now)
                  .contains("Blind spot"))

        // 2. Every tier says what the click will do, with and without a plan.
        for tier in FocusTier.allCases {
            check("tier \(tier.rawValue) has no click description",
                  !clickAction(tier: tier).isEmpty)
        }
        let cmux = FocusResolver.plan(pid: 2, psTTYField: "ttys000",
                                     hostBundlePath: "/Applications/cmux.app", tmuxTarget: nil)
        check("tier 2 sample is not tier 2", cmux.tier == .appOnly)
        check("tier 2 click text does not say the tab is untargetable",
              clickAction(tier: cmux.tier, plan: cmux).lowercased().contains("cannot target the tab"))
        check("a session without focus capability claims it can be raised",
              clickAction(tier: .windowAndTab, plan: cmux, canFocus: false)
                  .lowercased().contains("does nothing"))
        check("an unresolved focus plan optimistically claims tier 1",
              focusTier(detail(session: full, resolution: seeing)) == .impossible)
        check("a resolved plan lost its tier",
              focusTier(detail(session: full, resolution: seeing, focus: cmux)) == .appOnly)

        // 3. Inferred and reported must not read alike — that difference is the
        //    whole point of showing provenance.
        let inferredText = confidenceExplanation(state: .running, confidence: .inferred)
        let reportedText = confidenceExplanation(state: .running, confidence: .reported)
        check("inferred and reported are described identically", inferredText != reportedText)
        check("inferred description is empty", !inferredText.isEmpty)
        check("reported description is empty", !reportedText.isEmpty)
        check("inferred does not say it is unwitnessed",
              inferredText.lowercased().contains("not witnessed"))
        check("reported does not say it is witnessed",
              reportedText.lowercased().contains("witnessed"))
        check("the two provenance lines read alike",
              provenanceLine(state: .running, resolution: blind)
                  != provenanceLine(state: .running, resolution: seeing))

        // 4. Missing repo and branch drop their rows rather than render a label
        //    with nothing after it.
        let bare = AgentSession(
            id: "s2", backendID: "claude", title: "scratch", repoPath: nil, branch: nil,
            state: .idle, capabilities: .owned, lastTransition: t0
        )
        let bareRows = infoRows(session: bare, backendName: "Claude Code", now: now)
        check("a repo-less session still shows a Repo row",
              !bareRows.contains { $0.label == "Repo" })
        check("a branch-less session still shows a Branch row",
              !bareRows.contains { $0.label == "Branch" })
        for row in bareRows where row.value.trimmingCharacters(in: .whitespaces).isEmpty {
            failures.append("row '\(row.label)' rendered with an empty value")
        }
        for row in bareRows where row.label.isEmpty {
            failures.append("a row rendered with no label")
        }
        // Blank strings are not values either — a session titled with whitespace
        // must not turn into a labelled gap.
        let blank = AgentSession(id: "s3", backendID: "claude", title: "blank",
                                 repoPath: "   ", branch: "", lastTransition: t0)
        let blankRows = infoRows(session: blank, backendName: "Claude Code", now: now)
        check("a whitespace repo path became a row", !blankRows.contains { $0.label == "Repo" })
        check("an empty branch became a row", !blankRows.contains { $0.label == "Branch" })
        // The full session keeps everything, or the rows are being dropped wholesale.
        let fullRows = infoRows(session: full, backendName: "Claude Code", now: now)
        for label in ["Backend", "Repo", "Branch", "Can do", "Last change"] {
            check("a fully populated session is missing its \(label) row",
                  fullRows.contains { $0.label == label })
        }
        check("an empty slot rendered detail rows",
              infoRows(session: nil, backendName: "Claude Code", now: now).isEmpty)
        check("an empty slot announced a session",
              accessibilitySummary(detail(session: nil, resolution: seeing), now: now)
                  .contains("no session bound"))

        // 5. Every state yields a provenance line, whatever the reason text says.
        //    allCases, so an eighth state cannot ship without one.
        let reasons = [
            "claude.hooks reported running",
            "claude.transcript reported idle, but its process is gone",
            "no source has reported",
            "every source went quiet (2 stale reading(s))",
            "mock reported complete",
        ]
        for state in AgentState.allCases {
            for reason in reasons {
                for confidence in [StateConfidence.inferred, .reported] {
                    let line = provenanceLine(
                        state: state,
                        resolution: Resolution(state: state, confidence: confidence,
                                               liveness: .alive, reason: reason,
                                               unobservable: [])
                    )
                    if line.isEmpty {
                        failures.append("\(state.rawValue) has no provenance line for '\(reason)'")
                    }
                    if !line.contains(state.label) {
                        failures.append(
                            "provenance line '\(line)' omits the state word '\(state.label)'"
                        )
                    }
                }
            }
        }
        // Raw source ids must not leak where the reason is prose.
        check("prose reason was mistaken for a source id",
              sourceName(fromReason: "no source has reported") == nil)
        check("a known source id was not named",
              sourceName(fromReason: "claude.hooks reported running") == "Claude Code hooks")

        // 6. Capability summary states what is missing, not just what works.
        check("an observed session does not say it cannot approve",
              capabilitySummary(.observed).contains("cannot") &&
              capabilitySummary(.observed).contains("approve"))
        check("an owned session is described like an observed one",
              capabilitySummary(.owned) != capabilitySummary(.observed))
        check("a session with no capabilities has no summary",
              !capabilitySummary([]).isEmpty)

        // 7. Reduce Motion snaps.
        check("Reduce Motion still animates the popover contents",
              contentTransition(reduceMotion: true) == nil)
        check("contents do not animate when motion is allowed",
              contentTransition(reduceMotion: false) != nil)

        // 8. Nothing routes around the 9pt floor at the compact scale — the
        //    regression that produced 6.40pt labels last time.
        for base in [9, 10, 11, 13] as [CGFloat]
        where PanelLayout.compact.fontSize(base) < PanelLayout.minimumFontSize {
            failures.append("base \(base)pt resolves under the \(PanelLayout.minimumFontSize)pt floor")
        }

        return failures
    }
}
