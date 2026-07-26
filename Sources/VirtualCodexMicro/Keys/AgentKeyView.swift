import AppKit
import SwiftUI

/// One agent key. Six of these are the product: they carry the whole
/// at-a-glance proposition, so this is the brightest, most saturated thing on
/// the panel and every other control is tuned quieter than it.
///
/// Three rules shaped the code below, and they are worth stating because they
/// are what the self-check defends:
///
/// 1. **State is hue plus shape, always.** The reference caps carry no text —
///    they are frosted plastic with one small glyph in the middle — so the word
///    that used to sit on the face is gone. The second channel is therefore the
///    glyph, and it has to work harder for it: a different SF Symbol per state,
///    never one dot recoloured, with the full `AgentState.label` in the
///    VoiceOver value and the tooltip. `selfCheckFailures()` walks
///    `AgentState.allCases`, asserts all seven glyphs differ, and asserts each
///    resolves as a real symbol, so an eighth state cannot ship as colour-only
///    or as a duplicate mark.
/// 2. **Interaction never speaks in colour.** Hover, press and keyboard focus
///    change geometry only — lift, depress, detached ring. Fill opacity, glow
///    opacity and every colour are functions of state alone. A key that looks
///    like it changed status because the pointer crossed it would be the same
///    drift failure the state model exists to prevent, just caused by the mouse.
/// 3. **`unknown` is a lit key, `unassigned` is an empty one.** Different
///    motifs, not different shades: hatched and glowing with a question mark
///    versus dashed, unlit and quiet. "We lost track of a real session" and
///    "nothing here" must never be a squint apart.
///
/// Colour and geometry come from `StateColors` and `PanelLayout`. Nothing here
/// invents either.
public struct AgentKeyView: View {

    // MARK: - Decision types

    /// What kind of key face this is, before any interaction. Separate from
    /// `AgentState` because it is the *shape* language: three motifs cover
    /// seven states, and the two that must never be confused get their own.
    public enum Motif: String, Sendable, CaseIterable {
        /// No session bound. Dashed edge, unlit, no halo — an empty slot should
        /// look empty rather than look like a status.
        case emptySlot
        /// Bound, and we know what it is doing.
        case lit
        /// Bound, but the state source went quiet. Lit *and* hatched, so it
        /// reads as "occupied, unreadable" rather than "vacant".
        case lostTrack
    }

    /// Pointer/press treatment. Focus is a separate axis because it can coexist
    /// with either of these.
    public enum Treatment: String, Sendable, CaseIterable {
        case resting
        case hovered
        case pressed
    }

    public struct Interaction: Sendable, Equatable, Hashable {
        public var isHovered: Bool
        public var isPressed: Bool
        public var isFocused: Bool

        public init(isHovered: Bool = false, isPressed: Bool = false, isFocused: Bool = false) {
            self.isHovered = isHovered
            self.isPressed = isPressed
            self.isFocused = isFocused
        }

        public static let resting = Interaction()

        /// Press wins over hover: the pointer is always over a key it is
        /// pressing, and only one of the two can be the dominant reading.
        public var treatment: Treatment {
            isPressed ? .pressed : (isHovered ? .hovered : .resting)
        }
    }

    /// Every number the face draws with, resolved from state, interaction and
    /// accessibility settings. Deliberately holds no colours: colours are read
    /// from the swatch keyed by `state`, which is what makes it structurally
    /// impossible for an interaction to recolour a key.
    public struct Presentation: Sendable, Equatable {
        /// The state being reported. Interaction can never change this.
        public let state: AgentState
        public let treatment: Treatment
        public let motif: Motif
        public let isFocused: Bool
        /// Stable string naming the exact visual treatment. Exists so the
        /// self-check can prove two situations look different without
        /// rendering them.
        public let visualIdentifier: String

        /// From the swatch, or forced opaque under Reduce Transparency.
        public let fillOpacity: Double
        public let glowOpacity: Double
        public let glowRadius: Double
        public let edgeWidth: Double
        public let dashedEdge: Bool
        /// Frosted material behind the tint. False when Reduce Transparency is
        /// on, or when the fill is opaque anyway and the material would be
        /// invisible work.
        public let usesMaterial: Bool
        /// Moulded keycap: domed top highlight, shaded lower sidewall, and a
        /// shadow where the cap meets the plate. All three are soft translucent
        /// passes, so Reduce Transparency turns them off and the cap falls back
        /// to a flat fill with a thick edge.
        public let usesDepth: Bool

        /// Geometry-only interaction cues.
        public let scale: Double
        public let showsHoverRim: Bool
        public let showsFocusRing: Bool
    }

    // MARK: - Pure decision logic
    //
    // Everything below is static and side-effect free so it can be checked
    // without a render pass. `body` is assembly; the decisions live here.

    public static func motif(for state: AgentState) -> Motif {
        switch state {
        case .unassigned: .emptySlot
        case .unknown: .lostTrack
        case .idle, .running, .complete, .needsInput, .error: .lit
        }
    }

    /// Second, non-colour channel for status, and since the word came off the
    /// cap it is now the *only* on-panel channel besides hue. Never empty, never
    /// shared between two states — the self-check enforces both across
    /// `allCases`.
    ///
    /// Circle-framed on purpose: the reference caps all carry one small round
    /// glyph, so the family gives the panel the right silhouette. The mark
    /// *inside* the ring is what separates the states, which is why the ring is
    /// never the whole glyph. `error` breaks the family deliberately — an
    /// octagon reads as "stop" at a glance and at the far edge of vision, and
    /// "failed" is the reading this panel can least afford to lose.
    public static func iconName(for state: AgentState) -> String {
        switch state {
        case .unassigned: "circle.dashed"
        case .idle: "pause.circle"
        case .running: "play.circle.fill"
        case .complete: "checkmark.circle.fill"
        case .needsInput: "exclamationmark.circle.fill"
        case .error: "xmark.octagon.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    /// Identity only. Full session detail is a popover's job, not this view's.
    /// An `unassigned` slot never names a session even if one is passed, so a
    /// cleared slot cannot keep announcing the thread it used to hold.
    public static func accessibilityLabel(
        index: Int, session: AgentSession?, state: AgentState
    ) -> String {
        let slot = "Agent key \(index + 1)"
        guard state != .unassigned, let session else { return slot }
        return "\(slot), \(session.title)"
    }

    /// Spoken status. Contains `state.label` by construction so the text and
    /// the voice never drift apart.
    public static func accessibilityValue(for state: AgentState) -> String {
        switch state {
        case .unassigned: "\(state.label), no session bound"
        case .idle: state.label
        case .running: state.label
        case .complete: state.label
        case .needsInput: "\(state.label) for you"
        case .error: state.label
        // Spelled out: the whole point of this state is that the user
        // understands we are not guessing.
        case .unknown: "\(state.label), lost track of a bound session"
        }
    }

    /// What VoiceOver ends up reading, label then value. The self-check asserts
    /// against this whole string.
    public static func accessibilityDescription(
        index: Int, session: AgentSession?, state: AgentState
    ) -> String {
        accessibilityLabel(index: index, session: session, state: state)
            + ", " + accessibilityValue(for: state)
    }

    /// Maps the SwiftUI environment onto the appearance `StateColors` resolves
    /// against. Picking the case only — the colour maths stays in one file.
    public static func appearance(
        colorScheme: ColorScheme, increasedContrast: Bool
    ) -> StateColors.Appearance {
        switch (colorScheme == .dark, increasedContrast) {
        case (false, false): .light
        case (true, false): .dark
        case (false, true): .lightIncreasedContrast
        case (true, true): .darkIncreasedContrast
        }
    }

    /// Zero under Reduce Motion, which makes every transition snap.
    public static func stateTransitionDuration(reduceMotion: Bool) -> Double {
        reduceMotion ? 0 : 0.18
    }

    public static func stateTransition(reduceMotion: Bool) -> Animation {
        .easeOut(duration: stateTransitionDuration(reduceMotion: reduceMotion))
    }

    /// The one place state and interaction are combined.
    ///
    /// Note what interaction is allowed to touch: `scale`, the rim, the ring,
    /// and how far the halo spreads. Not `fillOpacity`, not `glowOpacity`, and
    /// not anything that selects a colour.
    public static func presentation(
        state: AgentState,
        interaction: Interaction = .resting,
        appearance: StateColors.Appearance,
        reduceTransparency: Bool
    ) -> Presentation {
        let swatch = StateColors.swatch(for: state, in: appearance)
        let treatment = interaction.treatment
        let motif = motif(for: state)

        // Reduce Transparency: solid face, edge thick enough to define it.
        let fillOpacity = reduceTransparency ? 1.0 : swatch.fillOpacity
        let edgeWidth = reduceTransparency ? max(swatch.edgeWidth, 1.5) : swatch.edgeWidth

        // Pressed tucks the halo under the key, the way a real key's light
        // would narrow as the cap goes down. A radius change, not a brightness
        // change, so it cannot read as a different state.
        let glowRadius = treatment == .pressed ? swatch.glowRadius * 0.45 : swatch.glowRadius

        let scale: Double = switch treatment {
        case .resting: 1.0
        case .hovered: 1.04   // lifts toward the pointer
        case .pressed: 0.955  // pushes into the panel
        }

        let identifier = "\(state.rawValue).\(motif.rawValue).\(treatment.rawValue)"
            + (interaction.isFocused ? "+focus" : "")

        return Presentation(
            state: state,
            treatment: treatment,
            motif: motif,
            isFocused: interaction.isFocused,
            visualIdentifier: identifier,
            fillOpacity: fillOpacity,
            glowOpacity: swatch.glowOpacity,
            glowRadius: glowRadius,
            edgeWidth: edgeWidth,
            dashedEdge: motif == .emptySlot,
            usesMaterial: !reduceTransparency && fillOpacity < 1,
            usesDepth: !reduceTransparency,
            scale: scale,
            showsHoverRim: treatment == .hovered,
            showsFocusRing: interaction.isFocused
        )
    }

    // MARK: - View

    private let index: Int
    private let state: AgentState
    private let session: AgentSession?
    private let layout: PanelLayout
    private let onActivate: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var isHovered = false
    @State private var isPulsing = false
    @FocusState private var isFocused: Bool

    /// `state` is passed explicitly rather than read from `session.state`: the
    /// state engine owns status, including driving a bound slot to `.unknown`
    /// when its source goes quiet. `session` is identity, nothing more.
    public init(
        index: Int,
        state: AgentState,
        session: AgentSession? = nil,
        layout: PanelLayout = .regular,
        onActivate: @escaping () -> Void = {}
    ) {
        self.index = index
        self.state = state
        self.session = session
        self.layout = layout
        self.onActivate = onActivate
    }

    public var body: some View {
        Button(action: onActivate) { Color.clear }
            .buttonStyle(FaceStyle { face(pressed: $0) })
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()  // we draw our own ring; the system's is a fifth language
            .onHover { isHovered = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(
                Self.accessibilityLabel(index: index, session: session, state: state)
            )
            .accessibilityValue(Self.accessibilityValue(for: state))
            .help(helpText)
            .animation(Self.stateTransition(reduceMotion: reduceMotion), value: state)
            .onAppear { isPulsing = shouldPulse }
            .onChange(of: shouldPulse) { _, now in isPulsing = now }
    }

    // MARK: - Geometry

    private var side: CGFloat { layout.agentKeyFrames[0].width }
    private var corner: CGFloat { layout.agentKeyCornerRadius }
    private var keyShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
    }

    private var appearance: StateColors.Appearance {
        Self.appearance(
            colorScheme: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    /// Only `running` breathes, and only when motion is allowed.
    private var shouldPulse: Bool { state == .running && !reduceMotion }

    private var helpText: String {
        Self.accessibilityDescription(index: index, session: session, state: state)
    }

    // MARK: - Face

    private func face(pressed: Bool) -> some View {
        let p = Self.presentation(
            state: state,
            interaction: Interaction(
                isHovered: isHovered, isPressed: pressed, isFocused: isFocused
            ),
            appearance: appearance,
            reduceTransparency: reduceTransparency
        )
        let swatch = StateColors.swatch(for: state, in: appearance)

        return ZStack {
            // Cap body. Material plus tint, in that order and at that opacity,
            // because this is exactly the stack `StateColors` measures: the
            // middle of the face composites to `composedKeyFill`, so the
            // luminance ladder the palette enforces is the ladder the eye gets.
            // Everything after this point is lighting, and lighting is not
            // allowed to repaint the centre.
            if p.usesMaterial {
                keyShape.fill(.ultraThinMaterial)
            }
            keyShape.fill(swatch.keyFill.color.opacity(p.fillOpacity))

            // The light lives inside the cap. Brightest at the middle, falling
            // off into the frosted sidewalls — which is what the reference
            // photographs show and the inverse of what this used to draw (a fat
            // blurred inner border, i.e. a lit rim around a flat centre).
            //
            // `glowRadius` becomes spread rather than blur, so a pressed key
            // still tucks its light in without any channel changing brightness.
            keyShape.fill(
                RadialGradient(
                    gradient: Gradient(colors: [
                        swatch.stateGlow.color,
                        swatch.stateGlow.color.opacity(0),
                    ]),
                    center: UnitPoint(x: 0.5, y: 0.44),
                    startRadius: 0,
                    endRadius: max(side * 0.2, side * (0.34 + p.glowRadius / 42))
                )
            )
            .opacity(p.glowOpacity * (isPulsing ? 0.5 : 1))
            .animation(pulseAnimation, value: isPulsing)

            if p.motif == .lostTrack {
                hatch(swatch)
            }

            if p.usesDepth {
                plasticShell
                moulding
            }

            keyShape.strokeBorder(swatch.keyEdge.color.opacity(0.85), style: edgeStyle(p))

            // Hover rim: a second line just inside the edge, in the key's own
            // colour. Reads as a raised bevel, says nothing about status.
            if p.showsHoverRim {
                keyShape
                    .inset(by: max(1.5, side * 0.055))
                    .strokeBorder(swatch.keyEdge.color.opacity(0.55), lineWidth: 1)
            }

            content(swatch, p)
        }
        .frame(width: side, height: side)
        .background {
            if p.usesDepth {
                plateShadow(pressed: p.treatment == .pressed)
                spill(swatch, p)
            }
        }
        .contentShape(keyShape)
        .scaleEffect(p.scale)
        .overlay { if p.showsFocusRing { focusRing(swatch) } }
    }

    /// Milky white plastic, drawn *over* the light — which is the whole change.
    /// The state colour underneath used to be the surface; now it is what is
    /// behind the surface, and this is the surface. Thin enough over the middle of
    /// the top face to let the LED through, thickening to near-opaque white at the
    /// sidewalls and corners the way a moulded cap does, which is what makes a lit
    /// cap read as white plastic containing colour instead of a coloured tile.
    ///
    /// One monotonic ramp, clear at the centre and climbing all the way out. Both
    /// halves of that matter:
    ///
    /// - **Monotonic**, because anything with a peak in it reads as a ring
    ///   painted on the cap rather than as plastic. An earlier version put the
    ///   brightness in an annulus, copying the moulded stem disc visible in the
    ///   photographs, and it came out a bullseye.
    /// - **Clear at the centre out to r≈0.19·side**, which clears a 17pt glyph.
    ///   That is the ladder's and the label's protection, and it is not slack:
    ///   `StateColors` measures both the 1.8 pairwise floor and the 4.5:1 label
    ///   contrast on `composedKeyFill`, i.e. on the middle of the face, and the
    ///   rendered stack has essentially no headroom there — the lit pairs
    ///   composite 1.78–1.87 apart before any white is added. White over the
    ///   centre would have closed the ladder, because near-black luminance moves
    ///   fastest per unit of white. White outside the glyph costs it nothing, so
    ///   the frost lives entirely in the band between the glyph and the edge.
    ///
    /// The corners sit past the last stop and take the whitest value, which is
    /// what the corner highlights on a real cap do, so the rounded square gets an
    /// even white perimeter out of a circular gradient for free.
    private var plasticShell: some View {
        keyShape.fill(
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.38),
                    .init(color: .white.opacity(0.04), location: 0.48),
                    .init(color: .white.opacity(0.10), location: 0.56),
                    .init(color: .white.opacity(0.18), location: 0.64),
                    .init(color: .white.opacity(0.28), location: 0.72),
                    .init(color: .white.opacity(0.40), location: 0.80),
                    .init(color: .white.opacity(0.55), location: 0.88),
                    .init(color: .white.opacity(0.68), location: 0.94),
                    .init(color: .white.opacity(0.80), location: 1),
                ]),
                center: .center,
                startRadius: 0,
                endRadius: side * 0.50
            )
        )
        // Softens the spoke banding a wide alpha ramp picks up when it is
        // rasterised at 1x. Clipped back to the cap so the blur cannot leak past
        // the silhouette and fog the plate.
        .blur(radius: side * 0.03)
        .clipShape(keyShape)
        .allowsHitTesting(false)
    }

    /// Domed top and shaded lower sidewall, in one pass.
    ///
    /// Achromatic deliberately: white plastic and its own shadow have no hue, so
    /// the state palette keeps its monopoly on colour and none of this can be
    /// mistaken for a state. It is also why the two halves are paired — the
    /// highlight lifts the top band and the shade drops the bottom band by a
    /// comparable amount, so the cap gains relief without the whole face
    /// drifting toward white. A uniform white frost over every cap would flatten
    /// the palette's luminance ladder, which is the one thing this restyle was
    /// not allowed to cost.
    private var moulding: some View {
        keyShape.fill(
            LinearGradient(
                stops: [
                    .init(color: .white.opacity(0.60), location: 0),
                    .init(color: .white.opacity(0.30), location: 0.06),
                    .init(color: .white.opacity(0.07), location: 0.30),
                    .init(color: .clear, location: 0.52),
                    .init(color: .black.opacity(0.05), location: 0.72),
                    .init(color: .black.opacity(0.20), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .allowsHitTesting(false)
    }

    /// Where the cap meets the plate. Drawn as its own blurred shape behind the
    /// key rather than a `.shadow` on the fill, because the fill is translucent
    /// and would let its own shadow darken the lower half of the face.
    private func plateShadow(pressed: Bool) -> some View {
        keyShape
            .fill(.black.opacity(pressed ? 0.14 : 0.24))
            .blur(radius: side * (pressed ? 0.05 : 0.09))
            .offset(y: side * (pressed ? 0.02 : 0.055))
            .allowsHitTesting(false)
    }

    /// Light escaping onto the plate around the cap. The single strongest cue in
    /// the reference photographs that the cap is *lit* rather than *painted*:
    /// pigment stops at the edge of the plastic, light does not. Blurred outside
    /// the shape so it never lands on the face, which keeps the ladder and the
    /// label contrast untouched. Brightness is `glowOpacity`, so it is a function
    /// of state alone; press narrows it via `glowRadius`, the same way the inner
    /// bloom already tucks in.
    private func spill(_ swatch: StateColors.StateSwatch, _ p: Presentation) -> some View {
        keyShape
            .fill(swatch.stateGlow.color)
            .blur(radius: side * (0.10 + p.glowRadius / 260))
            .opacity(p.glowOpacity * 0.55)
            .allowsHitTesting(false)
    }

    private var pulseAnimation: Animation? {
        isPulsing ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : nil
    }

    private func edgeStyle(_ p: Presentation) -> StrokeStyle {
        p.dashedEdge
            ? StrokeStyle(lineWidth: p.edgeWidth, dash: [side * 0.1, side * 0.07])
            : StrokeStyle(lineWidth: p.edgeWidth)
    }

    /// Diagonal hatch, `unknown` only. The plan called for it by name, and it
    /// is the cue that survives a glance at the far edge of the screen: a
    /// hatched key is occupied-but-unreadable, an empty one is never hatched.
    private func hatch(_ swatch: StateColors.StateSwatch) -> some View {
        let step = side * 0.17
        return Path { path in
            var x = -side
            while x <= side * 2 {
                path.move(to: CGPoint(x: x, y: side))
                path.addLine(to: CGPoint(x: x + side, y: 0))
                x += step
            }
        }
        .stroke(swatch.keyLabel.color.opacity(0.3), lineWidth: max(1, side * 0.02))
        .frame(width: side, height: side)
        .clipShape(keyShape)
        .allowsHitTesting(false)
    }

    /// One centred glyph, plus the slot number kept quiet in the corner.
    ///
    /// The state's word used to be here and is not any more: the reference caps
    /// have no text on them at all, and a word in 9pt on a 46pt cap was the main
    /// reason the panel did not look like the object. The word did not
    /// disappear, it moved — `accessibilityValue` and the tooltip both carry
    /// `state.label`, so the reading is still available on demand to everyone,
    /// it just is not silkscreened onto plastic that never had it.
    ///
    /// The number stays because six identical caps need addressing, but at a
    /// third of the glyph's presence, which is roughly where the reference's
    /// moulded markings sit.
    private func content(_ swatch: StateColors.StateSwatch, _ p: Presentation) -> some View {
        ZStack {
            Image(systemName: Self.iconName(for: state))
                .font(.system(
                    size: layout.fontSize(17),
                    weight: p.motif == .lostTrack ? .bold : .regular
                ))
                .opacity(p.motif == .emptySlot ? 0.6 : 0.92)
            // Dark ink rather than `keyLabel`, and not by preference. The number
            // sits in the corner, which is the one part of the face the frost
            // takes to near-white on every state and in both appearances — so a
            // white-labelled state used to put a white numeral on white plastic
            // and lose it. Engraved-grey is what the reference's own moulded
            // markings are, and unlike `keyLabel` it is legible against the
            // corner rather than against the centre `StateColors` measures.
            Text("\(index + 1)")
                .font(.system(size: layout.fontSize(9), weight: .semibold).monospacedDigit())
                .foregroundStyle(.black.opacity(0.42))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(swatch.keyLabel.color)
        .padding(side * 0.1)
    }

    /// Keyboard focus: a detached two-tone ring *outside* the key. Nothing else
    /// on the key draws outside its own bounds, so the gap alone identifies it.
    /// Two tones because one colour cannot be guaranteed visible against every
    /// backdrop, and the fill/label pair is already proven to contrast.
    private func focusRing(_ swatch: StateColors.StateSwatch) -> some View {
        let gap = max(2, side * 0.04)
        let outer = gap + 1.5
        return ZStack {
            RoundedRectangle(cornerRadius: corner + outer, style: .continuous)
                .strokeBorder(swatch.keyLabel.color, lineWidth: 1.5)
                .frame(width: side + outer * 2, height: side + outer * 2)
            RoundedRectangle(cornerRadius: corner + gap, style: .continuous)
                .strokeBorder(swatch.keyFill.color, lineWidth: 2)
                .frame(width: side + gap * 2, height: side + gap * 2)
        }
        .allowsHitTesting(false)
    }

    /// Exists only to hand `isPressed` back to the face. A `ButtonStyle` is the
    /// cheapest honest source of press state, and using a real `Button` means
    /// Space/Return activation and the button trait come for free.
    private struct FaceStyle<Face: View>: ButtonStyle {
        let face: (Bool) -> Face
        func makeBody(configuration: Configuration) -> Face { face(configuration.isPressed) }
    }

    // MARK: - Self check

    /// Rendering is not testable here, so the decision logic is what gets
    /// checked. Empty when healthy; wired into `SelfCheck` by the caller.
    public static func selfCheckFailures() -> [String] {
        var failures: [String] = []

        let session = AgentSession(id: "check-1", backendID: "check", title: "audit ledger sync")

        // 1. Status is never colour-only, for every state that exists now or
        //    later. allCases, so an eighth case fails here instead of shipping
        //    as a hue nobody can name.
        for state in AgentState.allCases {
            let description = accessibilityDescription(index: 0, session: session, state: state)
            if description.isEmpty {
                failures.append("\(state.rawValue) has no accessibility description")
            }
            if !description.contains(state.label) {
                failures.append(
                    "\(state.rawValue) description '\(description)' omits its label '\(state.label)'"
                )
            }
            if iconName(for: state).isEmpty {
                failures.append("\(state.rawValue) has no icon, leaving colour and text only")
            }
        }

        // 1b. The glyph is the only on-panel channel besides hue now that the
        //     word is off the cap, so two states sharing one mark would be a
        //     colour-only pair in practice. Pairwise, not a Set count, so the
        //     message names the collision.
        for (index, first) in AgentState.allCases.enumerated() {
            for second in AgentState.allCases.dropFirst(index + 1)
            where iconName(for: first) == iconName(for: second) {
                failures.append(
                    "\(first.rawValue) and \(second.rawValue) share the glyph \"\(iconName(for: first))\""
                )
            }
        }
        // A name that does not resolve draws nothing at all, which is the same
        // failure as having no second channel. Resolved, not trusted.
        for state in AgentState.allCases {
            let icon = iconName(for: state)
            if !icon.isEmpty,
               NSImage(systemSymbolName: icon, accessibilityDescription: nil) == nil {
                failures.append("\(state.rawValue) glyph \"\(icon)\" does not resolve as an SF Symbol")
            }
        }

        // 2. The distinction the whole design guards: bound-but-unreadable
        //    versus nothing here.
        let unknownDescription = accessibilityDescription(index: 2, session: session, state: .unknown)
        let unassignedDescription = accessibilityDescription(index: 2, session: nil, state: .unassigned)
        if unknownDescription == unassignedDescription {
            failures.append("unknown and unassigned read identically to VoiceOver")
        }
        if motif(for: .unknown) == motif(for: .unassigned) {
            failures.append("unknown and unassigned share a visual motif")
        }
        if iconName(for: .unknown) == iconName(for: .unassigned) {
            failures.append("unknown and unassigned share an icon")
        }

        // A cleared slot must not keep naming the session it used to hold.
        let staleSlot = accessibilityDescription(index: 2, session: session, state: .unassigned)
        if staleSlot.contains(session.title) {
            failures.append("an unassigned slot still announces '\(session.title)'")
        }

        // 3. Interaction is geometry, never status. Checked in every appearance
        //    because the swatch numbers differ per appearance.
        let interactions: [Interaction] = [
            .resting,
            Interaction(isHovered: true),
            Interaction(isPressed: true),
            Interaction(isFocused: true),
            Interaction(isHovered: true, isFocused: true),
        ]

        var identifiers = Set<String>()
        for appearance in StateColors.Appearance.allCases {
            for state in AgentState.allCases {
                let resting = presentation(
                    state: state, interaction: .resting,
                    appearance: appearance, reduceTransparency: false
                )
                for interaction in interactions {
                    let p = presentation(
                        state: state, interaction: interaction,
                        appearance: appearance, reduceTransparency: false
                    )
                    if p.state != state {
                        failures.append(
                            "\(interaction.treatment.rawValue) reports \(p.state.rawValue) on a \(state.rawValue) key"
                        )
                    }
                    if p.motif != resting.motif {
                        failures.append(
                            "\(state.rawValue) changes motif on \(interaction.treatment.rawValue)"
                        )
                    }
                    // The two brightness channels. If either moved on hover or
                    // press, a pointer could pass for a state change.
                    if p.fillOpacity != resting.fillOpacity {
                        failures.append(
                            "\(state.rawValue) fill brightens on \(interaction.treatment.rawValue)"
                        )
                    }
                    if p.glowOpacity != resting.glowOpacity {
                        failures.append(
                            "\(state.rawValue) glow brightens on \(interaction.treatment.rawValue)"
                        )
                    }
                    if appearance == .light { identifiers.insert(p.visualIdentifier) }
                }
            }
        }

        // 4. Each interactive treatment looks like itself, and like no state.
        //    Every state/interaction pair above is a distinct situation, so a
        //    collision means two of them render the same.
        let expected = AgentState.allCases.count * interactions.count
        if identifiers.count < expected {
            failures.append(
                "visual treatments collide: \(identifiers.count) identifiers for \(expected) situations"
            )
        }
        for state in AgentState.allCases {
            let variants = interactions.map {
                presentation(
                    state: state, interaction: $0,
                    appearance: .light, reduceTransparency: false
                )
            }
            if Set(variants.map(\.scale)).count < 3 {
                failures.append("\(state.rawValue): hover, press and rest are not three distinct sizes")
            }
            guard let hovered = variants.first(where: { $0.treatment == .hovered }),
                  let focusedOnly = variants.first(where: { $0.isFocused && $0.treatment == .resting })
            else {
                failures.append("\(state.rawValue): missing a hover or focus variant to compare")
                continue
            }
            if hovered.showsFocusRing || !focusedOnly.showsFocusRing {
                failures.append("\(state.rawValue): the focus ring does not track keyboard focus")
            }
            if focusedOnly.showsHoverRim {
                failures.append("\(state.rawValue): keyboard focus borrows the hover rim")
            }
        }

        // 5. Reduce Motion snaps.
        if stateTransitionDuration(reduceMotion: true) != 0 {
            failures.append("Reduce Motion still animates state transitions")
        }
        if stateTransitionDuration(reduceMotion: false) <= 0 {
            failures.append("state transitions do not animate when motion is allowed")
        }

        // 6. Reduce Transparency drops the frost for a solid face with an edge
        //    you can actually see.
        for appearance in StateColors.Appearance.allCases {
            for state in AgentState.allCases {
                let p = presentation(
                    state: state, appearance: appearance, reduceTransparency: true
                )
                if p.usesMaterial {
                    failures.append("\(state.rawValue) keeps the frosted material under Reduce Transparency")
                }
                if p.fillOpacity < 1 {
                    failures.append("\(state.rawValue) stays translucent under Reduce Transparency")
                }
                if p.edgeWidth < 1.5 {
                    failures.append("\(state.rawValue) has no defined edge under Reduce Transparency")
                }
                // The moulding and the plate shadow are translucent passes, so
                // they go with the frost rather than surviving it.
                if p.usesDepth {
                    failures.append("\(state.rawValue) keeps the moulded cap under Reduce Transparency")
                }
            }
        }

        // 7. Appearance mapping covers all four combinations.
        let mapped = Set([(false, false), (true, false), (false, true), (true, true)].map {
            appearance(colorScheme: $0.0 ? .dark : .light, increasedContrast: $0.1)
        })
        if mapped.count != StateColors.Appearance.allCases.count {
            failures.append("appearance mapping misses \(StateColors.Appearance.allCases.count - mapped.count) case(s)")
        }

        return failures
    }
}
