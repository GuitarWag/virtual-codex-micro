import CoreGraphics
import SwiftUI

/// The device itself: translucent case, inset plate, printed legends, screws, the
/// status cluster — and the state underglow, which is the reason this file exists.
///
/// ## The underglow is the product, the keys are the detail
///
/// An earlier version of the panel put the state colour inside each key and left
/// the case a static frosted rectangle. That is backwards. A lit key is only
/// information once you are already looking at the panel, and if you are already
/// looking at the panel you could have read the label. The reference photographs
/// (`docs/Codex-Micro-switch-options-RGB-Colors-*.jpg`) show what the hardware
/// actually does: the whole case washes in one colour and spills light past its
/// own outline onto the desk. That is peripheral, which is the only kind of
/// signal that works when your eyes are on your editor.
///
/// So the case gets one colour, drawn three ways: a soft halo behind and outside
/// the shell (`underglowLayers`), a wash through the translucent skirt
/// (`skirtWash`), and nothing at all on the plate, which stays white so the keys
/// keep their own channel.
///
/// ## One colour from six slots
///
/// `aggregateState(_:)` is the product decision, isolated as a pure function so
/// `selfCheckFailures()` can hold it still. The rule is **most urgent wins, not
/// most common**: a panel of five idle slots and one blocked one glows amber,
/// because the glow's whole job is to be the thing that makes you turn your head.
/// Counting or averaging would let five calm sessions bury the one that needs a
/// human, which is the failure mode the underglow exists to prevent.
///
/// ## Accessibility
///
/// Reduce Transparency: no material, no gradients over frost, and the halo
/// becomes a solid bounded band around the case. A soft haze is precisely what
/// that setting exists to remove, so the glow changes kind rather than just
/// getting stronger — it stops being light in the air and becomes an indicator
/// with an edge you can point at.
///
/// Reduce Motion: nothing here animates in any setting. The glow does not pulse,
/// breathe or sweep, so there is no motion to remove — state changes are step
/// changes in colour. That is deliberate: a pulsing case in peripheral vision is
/// an attention-grab that cannot be ignored, and the panel is meant to be
/// ignorable until it is not.
///
/// Colours: every state-driven value comes from `StateColors`. The neutral chrome
/// uses semantic AppKit colours plus relative white/black shading so one shell
/// description works in both appearances.
struct DeviceChrome: View {

    let layout: PanelLayout
    /// The six slot states, in key order. Short arrays are fine — missing slots
    /// simply do not vote.
    let states: [AgentState]
    /// When set, this is the glow colour, overriding the urgency ranking below.
    ///
    /// The ranking answers "what is the most urgent thing anywhere", which is right
    /// for an unattended panel but wrong once you are looking at a specific key: one
    /// stale failure pinned the whole case red and buried every later change. The
    /// owner passes the selected key's state, falling back to the most recent state
    /// received, so the glow tracks what you are actually attending to.
    var glowOverride: AgentState?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    // MARK: - Aggregate state

    /// Priority for the case glow. Lower wins. `nil` means "does not light the
    /// case at all", which only an empty slot may return.
    ///
    /// The order is an urgency order, not a lifecycle order:
    ///
    /// - `error` — something is broken and will stay broken until seen.
    /// - `needsInput` — blocked on a human; the panel is the human's notification.
    /// - `unknown` — we lost track of a real session. Ranked above the healthy
    ///   states on purpose: silently glowing "running" for a session we can no
    ///   longer see is the drift failure the PRD names as risk #1.
    /// - `running`, `complete`, `idle` — descending in how much they want you.
    ///
    /// A `switch` rather than a dictionary so an eighth `AgentState` is a compile
    /// error here instead of a slot that quietly stops voting.
    static func underglowRank(_ state: AgentState) -> Int? {
        switch state {
        case .unassigned: nil
        case .error: 0
        case .needsInput: 1
        case .unknown: 2
        case .running: 3
        case .complete: 4
        case .idle: 5
        }
    }

    /// The one colour the case wears, or `nil` for no glow at all.
    static func aggregateState(_ states: [AgentState]) -> AgentState? {
        states
            .compactMap { state in underglowRank(state).map { (state: state, rank: $0) } }
            .min { $0.rank < $1.rank }?
            .state
    }

    // MARK: - Underglow geometry

    /// Every number the halo draws with, so the accessibility behaviour is a value
    /// the self-check reads rather than a branch it has to render to see.
    struct Underglow: Sendable, Equatable {
        let state: AgentState
        /// How far the glow's *core* is pushed outside the case outline, in points.
        /// Kept inside `PanelLayout.glowBleed` together with `blurRadius` so the
        /// falloff lands in the reserved margin instead of being cut at the panel
        /// edge — a clipped gradient reads as a hard band, which is the one thing
        /// a halo must not look like.
        let spread: CGFloat
        /// 0 under Reduce Transparency.
        let blurRadius: CGFloat
        let opacity: Double
        /// Non-zero *only* under Reduce Transparency: the solid bounded band that
        /// replaces the haze.
        let ringWidth: CGFloat
    }

    static func underglow(
        for states: [AgentState],
        layout: PanelLayout,
        reduceTransparency: Bool,
        glowOverride: AgentState? = nil
    ) -> Underglow? {
        // An override still has to obey `underglowRank`'s rule that some states do
        // not light the case at all. Coalescing straight into the guard treated
        // `.unassigned` as a valid glow, so selecting an empty slot washed the case
        // in the empty-slot colour instead of going dark. Caught by this file's own
        // check rather than by looking at it.
        let resolved: AgentState? = if let glowOverride {
            underglowRank(glowOverride) == nil ? nil : glowOverride
        } else {
            aggregateState(states)
        }
        guard let state = resolved else { return nil }
        let bleed = PanelLayout.glowBleed * layout.scale
        return Underglow(
            state: state,
            // Spread nearly the whole bleed margin and blur WIDER than the spread.
            // The first pass blurred a 21pt band by 10pt and left it at 0.85 alpha,
            // which renders as a saturated picture frame — the failure mode here is
            // reading as coloured plastic instead of as light in the air. Light has
            // no edge, so the blur has to exceed the geometry it softens.
            // Spread stays near the case edge and the blur does the reaching. An
            // earlier attempt outset the shape almost to the panel edge, which put
            // the entire falloff OUTSIDE the captured bounds and left a crisp
            // clipped band — the glow has to fall off inside the bleed margin, not
            // past it.
            spread: bleed * 0.08,
            blurRadius: reduceTransparency ? 0 : bleed * 0.8,
            // Attention-worthy states push harder, but the ceiling stays low: this
            // is ambient spill on a desk, not a status light. Same two states the
            // overflow chip escalates on, read from `isAttentionWorthy`.
            opacity: reduceTransparency ? 1.0 : (state.isAttentionWorthy ? 0.55 : 0.32),
            ringWidth: reduceTransparency ? max(2, bleed * 0.16) : 0
        )
    }

    // MARK: - Printed legends
    //
    // The real plate reads "Work Louder | OpenAI 2026", "You can just build
    // things" and "Let's build". Those are another company's marks and printing
    // them on our panel is the branding risk the plan lists third — so the
    // positions, weight and voice are copied and the words are ours.

    enum Legend {
        /// Down the left side, where the hardware puts maker and year.
        static let left = "VIRTUAL PANEL · 2026"
        /// Down the right side, where the hardware puts its tagline.
        static let right = "eight keys, one glance"
        /// Above the grid: which way is up when it is face-down on a desk.
        static let orientation = "↑"
        /// Below the grid.
        static let bottom = "glance, don't stare"

        static var all: [String] { [left, right, orientation, bottom] }
    }

    // MARK: - Body

    var body: some View {
        let glow = Self.underglow(
            for: states, layout: layout, reduceTransparency: reduceTransparency,
            glowOverride: glowOverride
        )
        return ZStack {
            if let glow { underglowLayers(glow) }
            shell
            if let glow, glow.blurRadius > 0 { skirtWash(glow) }
            shellEdges
            plate
            screws
            legends
            statusCluster
        }
        .frame(width: layout.panelSize.width, height: layout.panelSize.height)
        // Chrome is scenery. The window is movable by its background, so leaving
        // the plate un-hit-testable makes every gap between keys a drag handle.
        .allowsHitTesting(false)
    }

    // MARK: - Shapes

    private func caseShape(outset: CGFloat = 0) -> Rounded {
        Rounded(
            rect: layout.caseFrame.insetBy(dx: -outset, dy: -outset),
            radius: layout.cornerRadius + outset
        )
    }

    private var plateShape: Rounded {
        Rounded(rect: layout.plateFrame, radius: layout.plateCornerRadius)
    }

    // MARK: - Underglow

    /// Light in the air: two feathered layers, the wider one carrying the reach and
    /// the tighter one the brightness near the case. Under Reduce Transparency both
    /// are replaced by one solid stroke.
    private func underglowLayers(_ glow: Underglow) -> some View {
        let color = StateColors.stateGlow(glow.state)
        return ZStack {
            if glow.ringWidth > 0 {
                caseShape(outset: glow.spread)
                    .strokeBorder(color, lineWidth: glow.ringWidth)
                    .opacity(glow.opacity)
            } else {
                // ONE layer, blurred by more than it is outset. Two stacked fills
                // at different blurs produced visible concentric bands — each
                // layer's own edge survived its blur and read as moulded plastic
                // rings. A single fill whose blur exceeds its offset has no edge
                // left to see, which is what makes it read as light.
                caseShape(outset: glow.spread)
                    .fill(color)
                    .blur(radius: glow.blurRadius)
                    .opacity(glow.opacity)
            }
        }
    }

    /// The colour seen *through* the case wall. A fat blurred inner border clipped
    /// to the shell, so the translucent skirt is tinted while the plate — drawn on
    /// top — stays neutral.
    private func skirtWash(_ glow: Underglow) -> some View {
        let inner = PanelLayout.caseInset * layout.scale
        // Thinner than the wall and blurred by more than its own width, so the
        // shell still reads as milky white with colour behind it. The earlier
        // 1.6x-wall stroke at 0.45x blur was wider than it was soft, which is what
        // made the case look moulded in the state colour.
        return caseShape()
            .strokeBorder(StateColors.stateGlow(glow.state), lineWidth: inner * 0.75)
            .blur(radius: inner * 1.1)
            .opacity(glow.opacity * 0.55)
            .clipShape(caseShape())
    }

    // MARK: - Shell

    /// Frosted milky plastic with thickness. The gradient is relative shading
    /// (white above, black below) over a semantic base, so one description reads
    /// as white plastic in the light appearance and dark plastic in the dark one
    /// without a second palette.
    private var shell: some View {
        ZStack {
            if reduceTransparency {
                caseShape().fill(Color(nsColor: .windowBackgroundColor))
            } else {
                caseShape().fill(.ultraThinMaterial)
                caseShape().fill(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.62), location: 0),
                            .init(color: .white.opacity(0.30), location: 0.45),
                            .init(color: .black.opacity(0.06), location: 1),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
    }

    /// What makes it read as a moulding rather than a rounded rectangle: a defined
    /// outer edge, a bright highlight just inside it, and the inner wall a few
    /// points further in.
    private var shellEdges: some View {
        let wall = PanelLayout.caseInset * layout.scale * 0.42
        return ZStack {
            caseShape()
                .strokeBorder(
                    Color.black.opacity(reduceTransparency ? 0.45 : 0.12),
                    lineWidth: reduceTransparency ? 1.5 : 0.75
                )
            caseShape().inset(by: 1.25)
                .strokeBorder(Color.white.opacity(reduceTransparency ? 0 : 0.55), lineWidth: 1)
            caseShape().inset(by: wall)
                .strokeBorder(Color.white.opacity(reduceTransparency ? 0 : 0.30), lineWidth: 0.75)
            caseShape().inset(by: wall + 1)
                .strokeBorder(Color.black.opacity(reduceTransparency ? 0.25 : 0.06), lineWidth: 0.75)
        }
    }

    // MARK: - Plate

    private var plate: some View {
        ZStack {
            plateShape
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.22), radius: 2.5, x: 0, y: 1)
            if !reduceTransparency {
                plateShape.fill(
                    LinearGradient(
                        colors: [.white.opacity(0.40), .white.opacity(0.06), .black.opacity(0.05)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
            plateShape.strokeBorder(
                Color.black.opacity(reduceTransparency ? 0.45 : 0.14),
                lineWidth: reduceTransparency ? 1.5 : 0.6
            )
            plateShape.inset(by: 1)
                .strokeBorder(Color.white.opacity(reduceTransparency ? 0 : 0.35), lineWidth: 0.75)
        }
    }

    // MARK: - Screws

    /// Four hex heads just inside the plate corners, as on the hardware. Recessed:
    /// a dark socket with a lighter hex glyph in it.
    private var screws: some View {
        let inset = 12 * layout.scale
        let diameter = 9 * layout.scale
        let plate = layout.plateFrame
        return ZStack {
            ForEach(0 ..< 4, id: \.self) { corner in
                screw(diameter: diameter)
                    .position(
                        x: corner % 2 == 0 ? plate.minX + inset : plate.maxX - inset,
                        y: corner < 2 ? plate.minY + inset : plate.maxY - inset
                    )
            }
        }
    }

    private func screw(diameter: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.16))
            Circle().inset(by: diameter * 0.14).fill(Color.black.opacity(0.62))
            Image(systemName: "hexagon.fill")
                .font(.system(size: diameter * 0.50))
                .foregroundStyle(Color.white.opacity(0.28))
        }
        .frame(width: diameter, height: diameter)
    }

    // MARK: - Legends

    private var legends: some View {
        let plate = layout.plateFrame
        let side = PanelLayout.plateInsetX * layout.scale / 2
        return ZStack {
            legendText(Legend.left)
                .rotationEffect(.degrees(-90))
                .position(x: plate.minX + side, y: plate.midY)
            legendText(Legend.right)
                .rotationEffect(.degrees(90))
                .position(x: plate.maxX - side, y: plate.midY)
            legendText(Legend.orientation, base: 11, weight: .regular)
                .position(x: plate.midX, y: plate.minY + PanelLayout.plateInsetTop * layout.scale / 2)
            legendText(Legend.bottom)
                .position(
                    x: plate.midX,
                    y: plate.maxY - PanelLayout.plateInsetBottom * layout.scale / 2
                )
        }
    }

    /// Printed, not UI: low contrast, tight tracking, never below the layout's font
    /// floor. `.secondary` rather than a literal so it survives both appearances.
    private func legendText(
        _ text: String, base: CGFloat = 8, weight: Font.Weight = .medium
    ) -> some View {
        Text(text)
            .font(.system(size: layout.fontSize(base), weight: weight))
            .kerning(0.4)
            .foregroundStyle(.secondary)
            .opacity(0.75)
            .fixedSize()
    }

    // MARK: - Status cluster

    /// Three indicator LEDs and the small dark button, printed in the bottom-left
    /// cell exactly as on the reference plate.
    ///
    /// The overflow chip targets this same cell and is drawn over this by
    /// `PanelRootView`. They do not fight because the chip is opaque and only
    /// exists when there are sessions without a key: either the plate art shows or
    /// the chip does, never both half-visible. The art is deliberately quiet —
    /// neutral greys, no halo — so the cell never competes with the six keys for
    /// the eye whichever of the two is on screen.
    private var statusCluster: some View {
        let cell = layout.statusClusterFrame
        let ledWidth = 5 * layout.scale
        let ledHeight = 2.5 * layout.scale
        let button = cell.height * 0.50
        return ZStack {
            VStack(spacing: 3 * layout.scale) {
                ForEach(0 ..< 3, id: \.self) { _ in
                    Capsule()
                        .fill(Color.secondary.opacity(0.40))
                        .frame(width: ledWidth, height: ledHeight)
                }
            }
            .position(x: cell.minX + ledWidth, y: cell.midY)

            ZStack {
                Circle().fill(Color.black.opacity(0.80))
                Circle().inset(by: 0.5).strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75)
            }
            .frame(width: button, height: button)
            .position(x: cell.midX + cell.width * 0.08, y: cell.midY)
        }
    }

    // MARK: - Self check

    /// Empty when healthy. Wire into `SelfCheck.run()` with:
    ///
    ///     failures += DeviceChrome.selfCheckFailures().map { "chrome: \($0)" }
    static func selfCheckFailures() -> [String] {
        var overrideFailures: [String] = []
        // The override must beat the ranking, and must beat it for EVERY state —
        // including the ones the ranking would otherwise suppress, which is the
        // whole point: a stale `error` used to pin the case red so no later change
        // could be seen. Driven from allCases so a new state is covered by default.
        let overrideFixture: [AgentState] = [.error, .needsInput, .running]
        for forced in AgentState.allCases where underglowRank(forced) != nil {
            let glow = underglow(for: overrideFixture, layout: .regular,
                                 reduceTransparency: false, glowOverride: forced)
            if glow?.state != forced {
                overrideFailures.append(
                    "glow override \(forced.rawValue) was ignored; got \(glow?.state.rawValue ?? "nil")"
                )
            }
        }
        // With no override the ranking still applies, or the unattended panel loses
        // its most-urgent-wins behaviour.
        if underglow(for: overrideFixture, layout: .regular, reduceTransparency: false)?.state != .error {
            overrideFailures.append("without an override the ranking no longer picks the most urgent state")
        }
        // An override of `unassigned` must not light the case: an empty slot is not
        // a status, and selecting one should go dark rather than glow grey.
        if underglow(for: [.unassigned], layout: .regular,
                     reduceTransparency: false, glowOverride: .unassigned) != nil {
            overrideFailures.append("an unassigned override lit the case")
        }

        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let slots = PanelLayout.agentKeyCount
        func filled(_ state: AgentState) -> [AgentState] {
            Array(repeating: state, count: slots)
        }

        // 1. Every state is either ranked or explicitly unlit, walked over
        //    allCases so an eighth state cannot ship silently unable to glow.
        var byRank: [Int: [AgentState]] = [:]
        for state in AgentState.allCases {
            guard let rank = underglowRank(state) else {
                check("\(state.rawValue) has no underglow rank but is not the empty slot",
                      state == .unassigned)
                continue
            }
            byRank[rank, default: []].append(state)
            // A ranked state must actually win on a panel of nothing else.
            var lone = filled(.unassigned)
            lone[0] = state
            check("a lone \(state.rawValue) slot does not light the case",
                  aggregateState(lone) == state)
        }
        for (rank, states) in byRank where states.count > 1 {
            failures.append(
                "states tie at underglow rank \(rank): "
                    + states.map(\.rawValue).sorted().joined(separator: ", ")
            )
        }

        // 2. The documented chain, every pair, with the stronger state outnumbered
        //    five to one. Ordering by count instead of urgency fails here.
        let chain: [AgentState] = [.error, .needsInput, .running, .complete, .idle]
        for (index, stronger) in chain.enumerated() {
            for weaker in chain.dropFirst(index + 1) {
                var mixed = filled(weaker)
                mixed[slots - 1] = stronger
                check(
                    "\(weaker.rawValue) x\(slots - 1) outranked one \(stronger.rawValue) in the underglow",
                    aggregateState(mixed) == stronger
                )
            }
        }
        // The chain must cover the ranked states, or a pair above went unchecked.
        let ranked = Set(AgentState.allCases.filter { underglowRank($0) != nil })
        for state in ranked.subtracting(chain) where state != .unknown {
            failures.append("\(state.rawValue) is ranked but not covered by the priority chain check")
        }

        // 3. Nothing bound, nothing lit. An empty panel must look switched off
        //    rather than glowing whatever colour "empty" happens to be.
        check("an all-empty panel still underglows", aggregateState(filled(.unassigned)) == nil)
        check("an empty slot list still underglows", aggregateState([]) == nil)
        check("an empty panel produced an underglow presentation",
              underglow(for: filled(.unassigned), layout: .regular, reduceTransparency: false) == nil)

        // 4. The case the whole rule exists for: one blocked slot among five idle
        //    ones owns the case, because peripheral means most urgent, not most
        //    common.
        var oneWaiting = filled(.idle)
        oneWaiting[3] = .needsInput
        check("one waiting slot among five idle ones did not take the underglow",
              aggregateState(oneWaiting) == .needsInput)
        check("the waiting underglow lost its colour",
              underglow(for: oneWaiting, layout: .regular, reduceTransparency: false)?.state == .needsInput)
        // And attention-worthy states must push harder than calm ones, or the
        // escalation is colour-only.
        if let waiting = underglow(for: oneWaiting, layout: .regular, reduceTransparency: false),
           let calm = underglow(for: filled(.idle), layout: .regular, reduceTransparency: false) {
            check("a waiting panel glows no harder than an idle one",
                  waiting.opacity > calm.opacity)
        } else {
            failures.append("an idle panel produced no underglow")
        }

        // 5. Accessibility, at every size class.
        for sizeClass in PanelLayout.SizeClass.allCases {
            let layout = PanelLayout(sizeClass: sizeClass)
            let tag = sizeClass.rawValue
            let bleed = PanelLayout.glowBleed * layout.scale
            guard
                let solid = underglow(for: filled(.error), layout: layout, reduceTransparency: true),
                let soft = underglow(for: filled(.error), layout: layout, reduceTransparency: false)
            else {
                failures.append("\(tag): a panel of errors produced no underglow")
                continue
            }
            check("\(tag): the underglow is still blurred under Reduce Transparency",
                  solid.blurRadius == 0)
            check("\(tag): the underglow has no bounded edge under Reduce Transparency",
                  solid.ringWidth >= 1.5)
            check("\(tag): the underglow stays translucent under Reduce Transparency",
                  solid.opacity >= 1)
            check("\(tag): the normal underglow is not soft", soft.blurRadius > 0)
            check("\(tag): the normal underglow draws a hard ring", soft.ringWidth == 0)
            check("\(tag): the underglow does not reach outside the case", soft.spread > 0)
            // Core plus falloff has to land inside the reserved margin, or the
            // gradient is cut at the panel edge and reads as a band.
            check("\(tag): the underglow needs \(soft.spread + soft.blurRadius)pt of the \(bleed)pt bleed and would clip",
                  soft.spread + soft.blurRadius <= bleed + 0.01)
        }

        // 6. The legends are ours. Positions copied from the hardware, wording not.
        for legend in Legend.all {
            check("a plate legend is empty", !legend.isEmpty)
            for mark in ["openai", "work louder", "codex"]
            where legend.lowercased().contains(mark) {
                failures.append("plate legend '\(legend)' carries the mark '\(mark)'")
            }
        }
        check("two plate legends are identical", Set(Legend.all).count == Legend.all.count)

        return overrideFailures + failures
    }
}

// MARK: - Absolute rounded rectangle

/// A squircle at fixed panel coordinates, ignoring whatever rect it is offered.
///
/// The chrome is one stack of concentric shapes at `PanelLayout`'s absolute rects,
/// and `.frame().position()` on each of a dozen layers is both noisier and easier
/// to get half a point wrong. `InsettableShape` so `strokeBorder` works, which is
/// what keeps every edge highlight *inside* the shell instead of straddling it.
private struct Rounded: InsettableShape {
    var rect: CGRect
    var radius: CGFloat
    var amount: CGFloat = 0

    func path(in _: CGRect) -> Path {
        Path(
            roundedRect: rect.insetBy(dx: amount, dy: amount),
            cornerRadius: max(0, radius - amount),
            style: .continuous
        )
    }

    func inset(by amount: CGFloat) -> Rounded {
        var copy = self
        copy.amount += amount
        return copy
    }
}
