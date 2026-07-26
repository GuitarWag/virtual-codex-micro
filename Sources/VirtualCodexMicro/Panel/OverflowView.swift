import AppKit
import CoreGraphics
import Foundation
import SwiftUI

/// What happens when there are more sessions than the six keys can hold.
///
/// The panel has six slots and a machine can easily have ten sessions. The PRD
/// left "how do we represent more than six agents" open; this is the answer, and
/// the answer has one rule everything else follows from:
///
/// **Silent truncation is not acceptable.** A blocked agent hidden behind an
/// overflow boundary is worse than no panel at all, because the user believes the
/// six keys are the whole world and acts on that belief. So there are two
/// separate guarantees here, and both are checked:
///
/// 1. **Nothing is dropped.** `SessionRegistry.unbound(from:)` already sorts
///    `needsInput` and `error` to the front; this view never re-sorts, never
///    filters and never caps. Paging walks the whole list, and
///    `selfCheckFailures()` pages through more sessions than fit on one page and
///    asserts every id appears exactly once.
/// 2. **The count is not enough.** "3 more" reads as "3 more calm ones". When any
///    unbound session is attention-worthy the indicator escalates: it wears that
///    state's colour, its icon, its word — and says so in the accessibility text,
///    because a screen-reader user needs the escalation exactly as much as a
///    sighted one. "3 more sessions, one waiting for input", never "3 more".
///
/// The indicator does **not** compete with the agent keys. It draws no halo at
/// all — `Presentation.glowOpacity` is structurally zero — so even at full amber
/// it is a chip beside the cluster rather than a seventh key. Glow is the keys'
/// channel and this borrows none of it.
///
/// Placement: the panel is 412x276 and all four zones are placed, but the strip
/// between the agent block's right edge (x 204) and the dial's left edge (x 288),
/// above the dial's top (y 84), is dead space at every size class. The chip sits
/// there — top-aligned with the first key row, adjacent to the cluster it is about,
/// touching no zone. `selfCheckFailures()` proves it clears every zone and every
/// hit target rather than asserting it in prose.
///
/// Colours come from `StateColors`, sizes from `PanelLayout.fontSize(_:)`. Reduce
/// Transparency drops the material for a solid fill and a thicker edge; Reduce
/// Motion removes the transition. Nothing here invents a colour or a size.
public struct OverflowView: View {

    // MARK: - Summary

    /// The counted facts behind the indicator. Built only by `summary(of:)`, which
    /// returns `nil` for an empty set — a zero badge would be a permanent piece of
    /// furniture claiming something exists.
    public struct Summary: Sendable, Equatable {
        public let count: Int
        public let needsInput: Int
        public let errors: Int
        /// Attention-worthy sessions that are neither `needsInput` nor `error`.
        /// Zero today, non-zero the moment an eighth state becomes attention-worthy
        /// — counted rather than assumed absent, so a new state cannot slip into
        /// the overflow list wearing the calm wording.
        public let otherAttention: Int
        /// Which swatch the chip wears when escalated. `unassigned` when nothing
        /// needs attention.
        public let escalationState: AgentState

        public var attentionCount: Int { needsInput + errors + otherAttention }
        public var isEscalated: Bool { attentionCount > 0 }
    }

    /// `nil` means render nothing at all. Deliberately not a zero-count summary:
    /// the difference between "no badge" and "a badge saying 0" is the difference
    /// between a quiet panel and a panel with a permanent nag on it.
    public static func summary(of unbound: [DiscoveredSession]) -> Summary? {
        guard !unbound.isEmpty else { return nil }
        let attention = unbound.map(\.session.state).filter(\.isAttentionWorthy)
        let needsInput = attention.filter { $0 == .needsInput }.count
        let errors = attention.filter { $0 == .error }.count
        return Summary(
            count: unbound.count,
            needsInput: needsInput,
            errors: errors,
            otherAttention: attention.count - needsInput - errors,
            // Same precedence as the registry's ordering, so the chip's colour
            // matches the first row of the list it opens.
            escalationState: attention.min { attentionRank($0) < attentionRank($1) } ?? .unassigned
        )
    }

    private static func attentionRank(_ state: AgentState) -> Int {
        switch state {
        case .needsInput: 0
        case .error: 1
        default: 2
        }
    }

    // MARK: - Wording
    //
    // Every string is built by a static function so the self-check asserts on
    // what a person or a screen reader actually receives. A boolean
    // "escalates correctly" would pass with an empty sentence.

    /// The one sentence that carries the whole promise. Visible as the tooltip,
    /// spoken as the accessibility label, and reused as the chooser's subtitle so
    /// the three can never drift apart.
    ///
    /// Escalated: `"3 more sessions, one waiting for input"`.
    /// Calm: `"3 more sessions, all quiet"`.
    ///
    /// "all quiet" is a claim, not filler — it is the sentence that makes the
    /// escalated version meaningful, and it must never appear when anything is
    /// waiting.
    public static func indicatorDescription(_ summary: Summary) -> String {
        let head = summary.count == 1 ? "1 more session" : "\(summary.count) more sessions"
        guard summary.isEscalated else { return "\(head), all quiet" }
        var clauses: [String] = []
        if summary.needsInput > 0 { clauses.append("\(spelled(summary.needsInput)) waiting for input") }
        if summary.errors > 0 { clauses.append("\(spelled(summary.errors)) in error") }
        if summary.otherAttention > 0 { clauses.append("\(spelled(summary.otherAttention)) needing attention") }
        return "\(head), " + clauses.joined(separator: ", ")
    }

    /// "one" reads as urgency, "1" reads as a table cell.
    private static func spelled(_ count: Int) -> String { count == 1 ? "one" : "\(count)" }

    /// Title, state, repo and branch in one line, for VoiceOver. Absent facts are
    /// absent rather than rendered as "branch: —".
    public static func rowDescription(_ found: DiscoveredSession) -> String {
        var line = "\(found.session.title), \(found.session.state.label)"
        if let location = locationLine(found.session) { line += " \(location)" }
        return line
    }

    /// "in ~/dev/acme on fix/rounding", or `nil` when neither fact exists.
    public static func locationLine(_ session: AgentSession) -> String? {
        var parts: [String] = []
        if let repo = trimmed(session.repoPath) {
            parts.append("in \((repo as NSString).abbreviatingWithTildeInPath)")
        }
        if let branch = trimmed(session.branch) { parts.append("on \(branch)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    /// A slot in the bind menu. Names the occupant it would displace: binding over
    /// an occupied key evicts whatever is there, and finding that out afterwards is
    /// how a user loses a key they thought they still had.
    public static func bindMenuTitle(slot: Int, occupant: String?) -> String {
        guard let occupant = trimmed(occupant) else { return "Key \(slot + 1) — empty" }
        return "Key \(slot + 1) — replaces \(occupant)"
    }

    public static func pageLabel(page: Int, pageCount: Int) -> String {
        "Page \(page + 1) of \(max(1, pageCount))"
    }

    // MARK: - Paging
    //
    // The count is unbounded, so the list is paged rather than grown. Paging is
    // where silent truncation would actually happen, so it is pure arithmetic in
    // two functions the self-check walks end to end.

    public static let sessionsPerPage = 5

    public static func pageCount(_ total: Int, perPage: Int = sessionsPerPage) -> Int {
        guard total > 0, perPage > 0 else { return 0 }
        return (total + perPage - 1) / perPage
    }

    /// The slice for one page, in the order given — this never sorts. The order is
    /// `SessionRegistry.unbound(from:)`'s, attention first, and re-deriving it here
    /// would be a second place for it to be wrong.
    public static func page(
        _ sessions: [DiscoveredSession], page: Int, perPage: Int = sessionsPerPage
    ) -> [DiscoveredSession] {
        guard perPage > 0 else { return sessions }
        let start = max(0, page) * perPage
        guard start < sessions.count else { return [] }
        return Array(sessions[start ..< min(sessions.count, start + perPage)])
    }

    // MARK: - Presentation

    /// Every number the chip draws with. Holds no colours — those come from the
    /// swatch keyed by `state` — and `glowOpacity` is a stored zero rather than an
    /// omission, so "the badge never out-glows a key" is a value the check reads.
    public struct Presentation: Sendable, Equatable {
        public let state: AgentState
        public let isEscalated: Bool
        public let iconName: String
        /// Short, because the chip is ~58pt wide at the compact scale. The exact
        /// count always survives in `indicatorDescription`.
        public let badgeText: String
        public let statusWord: String
        public let fillOpacity: Double
        public let edgeWidth: Double
        public let usesMaterial: Bool
        /// Always 0. The halo is the agent keys' channel and this borrows none of
        /// it — the chip must never read as a seventh key.
        public let glowOpacity: Double
        /// Stable string naming the exact treatment, so the check can prove calm
        /// and escalated look different without a render pass.
        public let visualIdentifier: String
    }

    public static func presentation(
        summary: Summary,
        appearance: StateColors.Appearance,
        reduceTransparency: Bool
    ) -> Presentation {
        let state = summary.isEscalated ? summary.escalationState : .unassigned
        let swatch = StateColors.swatch(for: state, in: appearance)
        // Reduce Transparency: solid face, edge thick enough to define it. Same
        // correction the dial and the pad needed after the a11y audit.
        let fillOpacity = reduceTransparency ? 1.0 : swatch.fillOpacity
        let edgeWidth = reduceTransparency ? max(swatch.edgeWidth, 1.5) : swatch.edgeWidth

        return Presentation(
            state: state,
            isEscalated: summary.isEscalated,
            // Escalated borrows the key's own icon so the chip and the key that
            // will hold it speak the same second channel. Calm gets `ellipsis`,
            // never `circle.dashed`: these are real sessions, not empty slots.
            iconName: summary.isEscalated ? AgentKeyView.iconName(for: state) : "ellipsis",
            badgeText: summary.count > 99 ? "99+" : "+\(summary.count)",
            statusWord: summary.isEscalated ? state.label : "quiet",
            fillOpacity: fillOpacity,
            edgeWidth: edgeWidth,
            usesMaterial: !reduceTransparency && fillOpacity < 1,
            glowOpacity: 0,
            visualIdentifier: "\(state.rawValue).\(summary.count).\(summary.attentionCount)"
        )
    }

    /// Zero under Reduce Motion, matching `AgentKeyView`.
    public static func transition(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.18)
    }

    // MARK: - Placement

    /// The dead strip between the agent block and the dial, above the dial's top
    /// edge. Derived from the zones rather than hardcoded, so a layout change moves
    /// the chip with them instead of leaving it on top of a key.
    ///
    /// Not added to `PanelLayout.hitTargets` because that file is not this task's
    /// to edit; the containment and overlap sweep is repeated here instead.
    /// The bottom-left grid cell. The reference device puts its status LEDs here,
    /// so the overflow count belongs there rather than in a gap between zones —
    /// and a full cell clears the hit floor at both size classes, which the old
    /// inter-zone strip did not once the grid became uniform.
    public static func indicatorFrame(_ layout: PanelLayout) -> CGRect {
        layout.statusClusterFrame
    }

    // MARK: - View

    private let unbound: [DiscoveredSession]
    private let layout: PanelLayout
    private let slotOccupants: [String?]
    private let onBind: (DiscoveredSession, Int) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var showsChooser = false
    @FocusState private var isFocused: Bool

    /// - Parameters:
    ///   - unbound: straight from `SessionRegistry.unbound(from:)`. Already in
    ///     priority order; this view never re-sorts it.
    ///   - slotOccupants: what each of the six keys currently holds, `nil` for
    ///     empty. Used only to warn about eviction in the bind menu.
    ///   - onBind: the registry is never mutated here. Binding is the caller's,
    ///     because a slot change has to go through `SessionRegistry.bind` with the
    ///     engine in hand.
    public init(
        unbound: [DiscoveredSession],
        layout: PanelLayout = .regular,
        slotOccupants: [String?] = [],
        onBind: @escaping (DiscoveredSession, Int) -> Void = { _, _ in }
    ) {
        self.unbound = unbound
        self.layout = layout
        self.slotOccupants = slotOccupants
        self.onBind = onBind
    }

    /// No summary means no view. Not a hidden zero badge, not a placeholder.
    public var body: some View {
        if let summary = Self.summary(of: unbound) {
            indicator(summary)
        }
    }

    private var appearance: StateColors.Appearance {
        AgentKeyView.appearance(
            colorScheme: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private func indicator(_ summary: Summary) -> some View {
        let p = Self.presentation(
            summary: summary, appearance: appearance, reduceTransparency: reduceTransparency
        )
        let swatch = StateColors.swatch(for: p.state, in: appearance)
        let frame = Self.indicatorFrame(layout)
        let description = Self.indicatorDescription(summary)

        return Button { showsChooser = true } label: {
            chipFace(p, swatch)
        }
        .buttonStyle(.plain)
        .frame(width: frame.width, height: frame.height)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .overlay { if isFocused { focusRing(swatch) } }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(description)
        .accessibilityHint("Opens the list of sessions with no key, the ones needing attention first.")
        .help(description)
        .animation(Self.transition(reduceMotion: reduceMotion), value: p.visualIdentifier)
        .popover(isPresented: $showsChooser) {
            OverflowChooser(
                unbound: unbound,
                layout: layout,
                slotOccupants: slotOccupants,
                onBind: { found, slot in
                    showsChooser = false
                    onBind(found, slot)
                }
            )
        }
    }

    private var chipShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: layout.commandKeyCornerRadius, style: .continuous)
    }

    /// Count, icon and word. No halo layer exists in this hierarchy at all — the
    /// keys keep that channel to themselves.
    private func chipFace(_ p: Presentation, _ swatch: StateColors.StateSwatch) -> some View {
        ZStack {
            if p.usesMaterial { chipShape.fill(.ultraThinMaterial) }
            chipShape.fill(swatch.keyFill.color.opacity(p.fillOpacity))
            chipShape.strokeBorder(swatch.keyEdge.color.opacity(0.85), lineWidth: p.edgeWidth)

            VStack(spacing: 0) {
                HStack(spacing: 3) {
                    Image(systemName: p.iconName)
                        .font(.system(size: layout.fontSize(9), weight: .semibold))
                    Text(p.badgeText)
                        .font(.system(size: layout.fontSize(11), weight: .semibold).monospacedDigit())
                }
                Text(p.statusWord)
                    .font(.system(size: layout.fontSize(9), weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(swatch.keyLabel.color)
            .padding(.horizontal, 4)
        }
        .contentShape(chipShape)
    }

    /// Keyboard focus, drawn outside the chip like the keys' own ring so the two
    /// read as the same affordance. Geometry only, never a colour change.
    private func focusRing(_ swatch: StateColors.StateSwatch) -> some View {
        RoundedRectangle(cornerRadius: layout.commandKeyCornerRadius + 3, style: .continuous)
            .strokeBorder(swatch.keyLabel.color, lineWidth: 1.5)
            .padding(-3)
            .allowsHitTesting(false)
    }

    // MARK: - Self check

    /// Empty when healthy. Wire into `SelfCheck.run()` with:
    ///
    ///     failures += OverflowView.selfCheckFailures().map { "overflow: \($0)" }
    ///
    /// Asserts on the strings a user or a screen reader actually gets, and pages
    /// through more sessions than fit on one page counting every id — that count
    /// is the silent-truncation guarantee.
    public static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        func found(
            _ id: String, _ state: AgentState,
            repo: String? = "/Users/x/dev/acme", branch: String? = "main"
        ) -> DiscoveredSession {
            DiscoveredSession(
                session: AgentSession(
                    id: id, backendID: "claude", title: "work on \(id)",
                    repoPath: repo, branch: branch, state: state
                ),
                pid: 1
            )
        }

        /// Priority order comes from the registry, never from this view, so the
        /// checks below order their fixtures the way the real caller does.
        func ordered(_ sessions: [DiscoveredSession]) -> [DiscoveredSession] {
            SessionRegistry(store: MemoryBindingStore()).unbound(from: sessions)
        }

        // 1. Escalation: one blocked session among three changes the sentence.
        guard let waiting = summary(of: [
            found("a", .idle), found("b", .needsInput), found("c", .running),
        ]) else {
            return failures + ["three unbound sessions produced no indicator at all"]
        }
        let waitingText = indicatorDescription(waiting)
        check(
            "escalated indicator '\(waitingText)' never says a session is waiting for input",
            waitingText.contains("waiting for input")
        )
        check("escalated indicator '\(waitingText)' lost the count", waitingText.contains("3"))
        check("a blocked unbound session did not escalate the indicator", waiting.isEscalated)
        check("escalation picked the wrong state to wear", waiting.escalationState == .needsInput)

        // 2. All quiet: the count alone, and no claim of attention anywhere in it.
        guard let quiet = summary(of: [
            found("a", .idle), found("b", .running), found("c", .complete),
        ]) else {
            return failures + ["three calm unbound sessions produced no indicator at all"]
        }
        let quietText = indicatorDescription(quiet)
        check("a calm indicator does not say the others are quiet: '\(quietText)'",
              quietText.contains("all quiet"))
        check("a calm indicator claims something is waiting: '\(quietText)'",
              !quietText.lowercased().contains("waiting"))
        check("a calm indicator claims an error: '\(quietText)'",
              !quietText.lowercased().contains("error"))
        check("a calm indicator claims attention: '\(quietText)'",
              !quietText.lowercased().contains("attention"))
        check("calm and escalated indicators read identically", quietText != waitingText)
        check("a calm overflow set escalated", !quiet.isEscalated)

        // And they must not *look* alike either, or the escalation is text-only.
        let quietFace = presentation(summary: quiet, appearance: .light, reduceTransparency: false)
        let waitingFace = presentation(summary: waiting, appearance: .light, reduceTransparency: false)
        check("calm and escalated chips share a treatment",
              quietFace.visualIdentifier != waitingFace.visualIdentifier)
        check("the escalated chip does not wear the waiting colour",
              waitingFace.state == .needsInput)
        check("the escalated chip does not wear the waiting word",
              waitingFace.statusWord == AgentState.needsInput.label)
        check("calm and escalated chips share an icon", quietFace.iconName != waitingFace.iconName)
        check("a calm chip wears the empty-slot icon, so it reads as a vacant key",
              quietFace.iconName != AgentKeyView.iconName(for: .unassigned))
        check("a calm chip has no icon at all", !quietFace.iconName.isEmpty)

        // 3. The keys stay the brightest thing on the panel. The chip has no halo
        //    in any appearance, escalated or not.
        for appearance in StateColors.Appearance.allCases {
            for summary in [quiet, waiting] {
                let p = presentation(summary: summary, appearance: appearance, reduceTransparency: false)
                if p.glowOpacity != 0 {
                    failures.append(
                        "the overflow chip glows (\(p.glowOpacity)) in \(appearance.rawValue), competing with the keys"
                    )
                }
            }
        }

        // 4. Every attention-worthy state escalates, walked over allCases so an
        //    eighth one cannot ship as a session hidden behind the calm wording.
        for state in AgentState.allCases where state.isAttentionWorthy {
            guard let summary = summary(of: [found("x", state), found("y", .idle)]) else {
                failures.append("an unbound \(state.rawValue) session produced no indicator")
                continue
            }
            let text = indicatorDescription(summary)
            check("an unbound \(state.rawValue) session did not escalate", summary.isEscalated)
            check("an unbound \(state.rawValue) session still reads 'all quiet': '\(text)'",
                  !text.contains("all quiet"))
            let p = presentation(summary: summary, appearance: .light, reduceTransparency: false)
            check("\(state.rawValue) escalation does not carry an attention colour",
                  p.state.isAttentionWorthy)
            check("\(state.rawValue) escalation has no icon", !p.iconName.isEmpty)
            check("\(state.rawValue) escalation has no word", !p.statusWord.isEmpty)
        }
        for state in AgentState.allCases where !state.isAttentionWorthy {
            if let summary = summary(of: [found("x", state)]) {
                check("a calm \(state.rawValue) session escalated the indicator", !summary.isEscalated)
            }
        }
        // needsInput outranks error when both are waiting, matching the list order.
        if let both = summary(of: [found("e", .error), found("w", .needsInput)]) {
            check("error outranked needsInput on the chip", both.escalationState == .needsInput)
            let text = indicatorDescription(both)
            check("a mixed overflow set drops the error count: '\(text)'", text.contains("in error"))
            check("a mixed overflow set drops the waiting count: '\(text)'",
                  text.contains("waiting for input"))
        } else {
            failures.append("a waiting-plus-error overflow set produced no indicator")
        }

        // 5. An empty unbound set renders nothing — not a zero badge.
        check("an empty unbound set still produced an indicator", summary(of: []) == nil)
        check("an empty unbound set claims a page", pageCount(0) == 0)
        check("an empty unbound set yields rows", page([], page: 0).isEmpty)

        // 6. The list preserves the registry's priority order for a mixed set,
        //    across page boundaries.
        let mixed = ordered([
            found("z-idle", .idle),
            found("m-error", .error),
            found("a-running", .running),
            found("y-waiting", .needsInput),
            found("b-error", .error),
        ])
        check("fixture drifted: the registry no longer sorts needsInput first",
              mixed.first?.id == "y-waiting")
        let walked = (0 ..< pageCount(mixed.count, perPage: 2))
            .flatMap { page(mixed, page: $0, perPage: 2) }
            .map(\.id)
        check("paging reordered the registry's priority order: \(walked)",
              walked == mixed.map(\.id))
        check("a two-per-page walk of five sessions lost one", walked.count == 5)

        // 7. The silent-truncation guarantee. More sessions than one page, paged
        //    end to end, every id seen exactly once — and the single blocked one
        //    lands on the first page rather than behind a Next button.
        let many = ordered((0 ..< 13).map { index in
            found(String(format: "s%02d", index), index == 11 ? .needsInput : .idle)
        })
        let pages = pageCount(many.count)
        check("13 sessions at \(sessionsPerPage) per page is not more than one page", pages > 1)
        check("13 sessions at \(sessionsPerPage) per page should be 3 pages, got \(pages)", pages == 3)
        var seen: [String: Int] = [:]
        for index in 0 ..< pages {
            let rows = page(many, page: index)
            check("page \(index) of \(pages) is empty", !rows.isEmpty)
            check("page \(index) holds \(rows.count) rows, over the \(sessionsPerPage) limit",
                  rows.count <= sessionsPerPage)
            for row in rows { seen[row.id, default: 0] += 1 }
        }
        check("paging changed the number of sessions: \(seen.count) seen, \(many.count) given",
              seen.count == many.count)
        for session in many where seen[session.id] != 1 {
            failures.append(
                "session \(session.id) appears \(seen[session.id] ?? 0) times across \(pages) pages, not once"
            )
        }
        check("a page past the end is not empty", page(many, page: pages).isEmpty)
        check("a negative page index escapes the first page",
              page(many, page: -1).map(\.id) == page(many, page: 0).map(\.id))
        check("the one waiting session is not on the first page",
              page(many, page: 0).contains { $0.session.state == .needsInput })
        check("page labels are 1-based", pageLabel(page: 0, pageCount: pages) == "Page 1 of 3")

        // 8. A three-figure count clamps the chip text but never the sentence.
        guard let crowd = summary(of: (0 ..< 120).map { found("c\($0)", .idle) }) else {
            return failures + ["120 unbound sessions produced no indicator"]
        }
        let crowdFace = presentation(summary: crowd, appearance: .light, reduceTransparency: false)
        check("a 120-session chip does not clamp its text", crowdFace.badgeText == "99+")
        check("a clamped chip lost the real count from its description",
              indicatorDescription(crowd).contains("120"))

        // 9. Singular reads as a sentence, not as a table cell.
        if let one = summary(of: [found("solo", .idle)]) {
            check("a single quiet session reads plural: '\(indicatorDescription(one))'",
                  indicatorDescription(one) == "1 more session, all quiet")
        } else {
            failures.append("one unbound session produced no indicator")
        }
        if let oneWaiting = summary(of: [found("solo", .needsInput)]) {
            check("a single blocked session reads as a count: '\(indicatorDescription(oneWaiting))'",
                  indicatorDescription(oneWaiting) == "1 more session, one waiting for input")
        } else {
            failures.append("one blocked unbound session produced no indicator")
        }

        // 10. Rows carry state, title, repo and branch — and drop absent facts
        //     rather than rendering a label with nothing after it.
        let rich = found("r", .needsInput, repo: "/Users/x/dev/acme", branch: "fix/rounding")
        let richRow = rowDescription(rich)
        for fragment in ["work on r", AgentState.needsInput.label, "acme", "fix/rounding"] {
            check("row '\(richRow)' omits '\(fragment)'", richRow.contains(fragment))
        }
        let bare = found("b", .idle, repo: nil, branch: nil)
        check("a repo-less, branch-less row invented a location",
              locationLine(bare.session) == nil)
        check("a bare row still names its state",
              rowDescription(bare).contains(AgentState.idle.label))
        let blank = found("w", .idle, repo: "   ", branch: "")
        check("a whitespace repo became a location", locationLine(blank.session) == nil)
        // Every state produces a readable row, so a new state cannot render blank.
        for state in AgentState.allCases {
            let row = rowDescription(found("s", state))
            check("a \(state.rawValue) row is empty", !row.isEmpty)
            check("row '\(row)' omits the state word '\(state.label)'", row.contains(state.label))
        }

        // 11. The bind menu says what it would displace.
        check("an empty key does not say it is empty",
              bindMenuTitle(slot: 2, occupant: nil).contains("empty"))
        check("the bind menu is 0-indexed to the user",
              bindMenuTitle(slot: 2, occupant: nil).contains("Key 3"))
        check("binding over an occupied key does not warn it replaces the occupant",
              bindMenuTitle(slot: 0, occupant: "chase flaky test")
                  .contains("replaces chase flaky test"))
        check("a whitespace occupant reads as a real one",
              bindMenuTitle(slot: 0, occupant: "  ").contains("empty"))

        // 12. Reduce Transparency and Reduce Motion, both of which two other
        //     components had to be corrected for.
        for appearance in StateColors.Appearance.allCases {
            for summary in [quiet, waiting, crowd] {
                let p = presentation(summary: summary, appearance: appearance, reduceTransparency: true)
                if p.usesMaterial {
                    failures.append("the chip keeps the frosted material under Reduce Transparency in \(appearance.rawValue)")
                }
                if p.fillOpacity < 1 {
                    failures.append("the chip stays translucent under Reduce Transparency in \(appearance.rawValue)")
                }
                if p.edgeWidth < 1.5 {
                    failures.append("the chip has no defined edge under Reduce Transparency in \(appearance.rawValue)")
                }
            }
        }
        check("Reduce Motion still animates the overflow chip", transition(reduceMotion: true) == nil)
        check("the chip does not animate when motion is allowed", transition(reduceMotion: false) != nil)

        // 13. Placement: it fits in the dead strip without touching a zone, a key
        //     or the panel edge, at every size class — and stays clickable.
        let epsilon: CGFloat = 0.01
        for sizeClass in PanelLayout.SizeClass.allCases {
            let layout = PanelLayout(sizeClass: sizeClass)
            let frame = indicatorFrame(layout)
            let tag = sizeClass.rawValue
            if min(frame.width, frame.height) < PanelLayout.minimumHitTarget - epsilon {
                failures.append(
                    "\(tag): the overflow chip is \(frame.width)x\(frame.height), under the \(PanelLayout.minimumHitTarget)pt hit floor"
                )
            }
            if !layout.panelBounds.insetBy(dx: -epsilon, dy: -epsilon).contains(frame) {
                failures.append("\(tag): the overflow chip escapes the panel")
            }
            // Zone comparison dropped deliberately: zones became logical bounding
            // boxes when the layout went to one uniform grid, so they overlap each
            // other by construction and overlapping one carries no meaning. Only
            // target-vs-target collision does — and the chip now IS a target, so it
            // must not be compared against its own entry.
            for target in layout.hitTargets
            where !target.nested && target.name != "overflow"
                && target.frame.insetBy(dx: epsilon, dy: epsilon)
                    .intersects(frame.insetBy(dx: epsilon, dy: epsilon)) {
                failures.append("\(tag): the overflow chip overlaps \(target.name)")
            }
            // Every label the chip and the chooser draw, routed through the clamp.
            for base in [9, 10, 11, 13] as [CGFloat] where layout.fontSize(base) < PanelLayout.minimumFontSize {
                failures.append(
                    "\(tag): base \(base)pt label resolves to \(layout.fontSize(base))pt, under the \(PanelLayout.minimumFontSize)pt floor"
                )
            }
        }

        return failures
    }
}

// MARK: - Chooser

/// The list behind the chip: every session with no key, in the registry's order,
/// with a way to give one a key.
///
/// Paged rather than scrolled. The count is unbounded, and a fixed-height popover
/// with an explicit "Page 2 of 4" tells the user how much they have not seen —
/// which a scroll view with a short thumb does not.
///
/// Binds through a closure. This view never touches `SessionRegistry`: a slot
/// change has to go through `bind(_:to:engine:at:)` with the state engine in hand,
/// and a view that reached around that would be the auto-adopt the registry exists
/// to prevent.
public struct OverflowChooser: View {
    private let unbound: [DiscoveredSession]
    private let layout: PanelLayout
    private let slotOccupants: [String?]
    private let onBind: (DiscoveredSession, Int) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var pageIndex = 0

    public init(
        unbound: [DiscoveredSession],
        layout: PanelLayout = .regular,
        slotOccupants: [String?] = [],
        onBind: @escaping (DiscoveredSession, Int) -> Void = { _, _ in }
    ) {
        self.unbound = unbound
        self.layout = layout
        self.slotOccupants = slotOccupants
        self.onBind = onBind
    }

    public var body: some View {
        let pages = max(1, OverflowView.pageCount(unbound.count))
        // Clamped rather than trusted: the list shrinks under us whenever a
        // session is bound or ends, and a stale index would render a blank page
        // that looks exactly like truncation.
        let current = min(max(0, pageIndex), pages - 1)

        return VStack(alignment: .leading, spacing: 8) {
            header
            if unbound.isEmpty {
                Text("Every session has a key.")
                    .font(.system(size: layout.fontSize(11)))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(OverflowView.page(unbound, page: current), id: \.id) { row($0) }
                if pages > 1 { pager(current: current, pages: pages) }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(background)
    }

    private var appearance: StateColors.Appearance {
        AgentKeyView.appearance(
            colorScheme: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    /// Reduce Transparency: opaque surface plus an edge you can actually find.
    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            shape.fill(reduceTransparency
                ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                : AnyShapeStyle(.ultraThinMaterial))
            shape.strokeBorder(.quaternary, lineWidth: reduceTransparency ? 1.5 : 0.5)
        }
    }

    /// The same sentence the chip carries, so what the user heard from the badge is
    /// what they read at the top of the list.
    private var header: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Sessions without a key")
                .font(.system(size: layout.fontSize(13), weight: .semibold))
            if let summary = OverflowView.summary(of: unbound) {
                Text(OverflowView.indicatorDescription(summary))
                    .font(.system(size: layout.fontSize(10)))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ found: DiscoveredSession) -> some View {
        HStack(alignment: .center, spacing: 8) {
            stateChip(found.session.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(found.session.title)
                    .font(.system(size: layout.fontSize(11), weight: .medium))
                    .lineLimit(1)
                if let location = OverflowView.locationLine(found.session) {
                    Text(location)
                        .font(.system(size: layout.fontSize(9)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            // One a11y element for the text block; the menu stays separately
            // focusable so keyboard users can reach it.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(OverflowView.rowDescription(found))
            Spacer(minLength: 4)
            Menu("Bind…") {
                ForEach(0 ..< PanelLayout.agentKeyCount, id: \.self) { slot in
                    Button(OverflowView.bindMenuTitle(slot: slot, occupant: occupant(slot))) {
                        onBind(found, slot)
                    }
                }
            }
            .font(.system(size: layout.fontSize(10)))
            .fixedSize()
            .accessibilityLabel("Bind \(found.session.title) to a key")
            .accessibilityHint("Choose which of the six keys this session takes.")
        }
    }

    private func occupant(_ slot: Int) -> String? {
        slotOccupants.indices.contains(slot) ? slotOccupants[slot] : nil
    }

    /// State as hue *and* word, the same rule the keys follow.
    private func stateChip(_ state: AgentState) -> some View {
        let swatch = StateColors.swatch(for: state, in: appearance)
        return Text(state.label)
            .font(.system(size: layout.fontSize(9), weight: .semibold))
            .foregroundStyle(swatch.keyLabel.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(
                    swatch.keyFill.color.opacity(reduceTransparency ? 1 : swatch.fillOpacity)
                )
            )
            .overlay(Capsule().strokeBorder(
                swatch.keyEdge.color.opacity(0.6),
                lineWidth: reduceTransparency ? 1.5 : 0.5
            ))
    }

    /// Plain buttons: Tab reaches them, Space and Return fire them. The page label
    /// says how many pages exist, so what is off-screen is stated rather than
    /// implied by a scroll thumb.
    private func pager(current: Int, pages: Int) -> some View {
        HStack(spacing: 8) {
            Button("Previous") { pageIndex = max(0, current - 1) }
                .disabled(current == 0)
            Text(OverflowView.pageLabel(page: current, pageCount: pages))
                .font(.system(size: layout.fontSize(9)))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("Next") { pageIndex = min(pages - 1, current + 1) }
                .disabled(current >= pages - 1)
        }
        .font(.system(size: layout.fontSize(10)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(OverflowView.pageLabel(page: current, pageCount: pages)), \(unbound.count) sessions in total"
        )
    }
}
