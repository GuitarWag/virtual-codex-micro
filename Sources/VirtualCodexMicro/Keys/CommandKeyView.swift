import AppKit
import SwiftUI

/// The six fixed-purpose command keys: the quieter cluster next to the agent
/// keys. One thin line icon on an opaque near-white cap, no caption and no state
/// glow — the agent keys carry the at-a-glance proposition and stay the only
/// coloured, lit things on the panel. That division is the reference device's,
/// not a preference: its command caps are solid white plastic and only the agent
/// caps are translucent and backlit.
///
/// Disabled is a first-class visual state here rather than an afterthought.
/// Per PLAN.md's owned-vs-observed correction: a `claude` session the user
/// started in their own terminal can be watched and raised, but not typed into.
/// Approving a pending diff by injecting keystrokes into whichever terminal pane
/// happens to have focus is the thing that demos well and corrupts a branch at
/// 3am. So accept and reject genuinely cannot fire on an observed session, and
/// the key has to look unavailable and say why on hover instead of looking live
/// and swallowing the click.
///
/// Positions are muscle memory. All six slots always render at their
/// `PanelLayout.commandKeyFrame(_:)` position — an unavailable key dims, it
/// never reflows, collapses or disappears.
///
/// The key does not build an `AgentCommand`; it reports which slot fired and the
/// owner turns that into a command. Push-to-talk's payload only exists after the
/// recording ends, so a slot-to-command map would be a lie for one of six cases.
public struct CommandKeyView: View {

    // MARK: - Capability gating (pure, testable)

    /// Every write path into a session goes through stdin on a PTY we own. Used
    /// to tell "observed session" apart from "owned session that happens to be
    /// missing one capability", so the hover text can be specific.
    private static let stdinBacked: SessionCapabilities = [.approve, .reject, .sendPrompt, .setEffort]

    /// The capability a slot needs from the *bound* session, or `nil` when the
    /// slot does not act on the bound session at all.
    ///
    /// `newSession` is that `nil`. It is the one key whose target does not exist
    /// yet: it asks the app to spawn a fresh session under its own PTY, so
    /// reading the currently bound session's capabilities would gate it on the
    /// wrong object entirely — a slot bound to an observed session would refuse
    /// to start an owned one, which is backwards. PLAN.md's matrix says exactly
    /// this by marking new-session "n/a" rather than "no" for observed sessions.
    /// What it does require is a backend that can spawn, which is a property of
    /// the app's connections, so it arrives as `canSpawnSessions` instead.
    ///
    /// Custom 1 and 2 need `.sendPrompt`: their default binding is a canned
    /// prompt or slash command, which is stdin, same as anything else we type.
    /// Remapping lands in M3; if a custom key ever binds to a non-stdin action
    /// this mapping is where that changes.
    public static func requiredCapability(for slot: PanelLayout.CommandSlot) -> SessionCapabilities? {
        switch slot {
        case .accept: .approve
        case .reject: .reject
        case .newSession: nil
        case .pushToTalk: .sendPrompt
        case .custom1: .sendPrompt
        case .custom2: .sendPrompt
        }
    }

    /// `capabilities` is `nil` when no session is bound to the panel yet.
    ///
    /// Deliberately not written as `unavailabilityReason(...) == nil`: the two
    /// functions decide independently and `selfCheckFailures()` asserts they
    /// agree, so a key can never end up live with an explanation attached, or
    /// dead with nothing to say.
    public static func isEnabled(
        _ slot: PanelLayout.CommandSlot,
        capabilities: SessionCapabilities?,
        canSpawnSessions: Bool = true
    ) -> Bool {
        guard let required = requiredCapability(for: slot) else { return canSpawnSessions }
        guard let capabilities else { return false }
        return capabilities.contains(required)
    }

    /// Why this key cannot fire, or `nil` when it can. Shown on hover, and it is
    /// also the VoiceOver label when disabled — one string, so the pointer user
    /// and the screen reader user get the same explanation.
    public static func unavailabilityReason(
        for slot: PanelLayout.CommandSlot,
        capabilities: SessionCapabilities?,
        canSpawnSessions: Bool = true
    ) -> String? {
        let action = actionName(for: slot)

        guard let required = requiredCapability(for: slot) else {
            // newSession: gated on the app, not on the bound session.
            return canSpawnSessions
                ? nil
                : "\(action) is unavailable: no connected backend can start a session."
        }

        guard let capabilities else {
            return "\(action) is unavailable: no session is bound to the panel yet."
        }
        guard !capabilities.contains(required) else { return nil }

        if capabilities.isDisjoint(with: stdinBacked) {
            return "\(action) is unavailable: this session can only be observed. "
                + "The panel can show its state and bring it to the front, but it cannot type "
                + "into a terminal it does not own."
        }
        return "\(action) is unavailable: this session did not declare the "
            + "\(capabilityName(required)) capability."
    }

    private static func capabilityName(_ capability: SessionCapabilities) -> String {
        if capability == .approve { return "approve" }
        if capability == .reject { return "reject" }
        if capability == .sendPrompt { return "send prompt" }
        if capability == .setEffort { return "set effort" }
        if capability == .focus { return "focus" }
        return "required"
    }

    // MARK: - Slot presentation

    /// Spoken and hover name. The only place these keys carry words: the
    /// reference caps are bare white plastic with one thin line icon and no
    /// legend, so `actionName` reaches the user through the tooltip and
    /// VoiceOver instead of through 8pt type on a 46pt cap. There used to be a
    /// `keyLabel` returning "c1"/"talk" for the face; a two-character caption is
    /// not the thing that rescues an unlabelled key anyway — the hover text is.
    public static func actionName(for slot: PanelLayout.CommandSlot) -> String {
        switch slot {
        case .accept: "Accept"
        case .reject: "Reject"
        case .newSession: "New session"
        case .pushToTalk: "Push to talk"
        case .custom1: "Custom 1"
        case .custom2: "Custom 2"
        }
    }

    /// The icons the hardware actually has, read off the top-down reference: a
    /// lightning bolt, a check in a circle, an X in a circle, a diverging arrow,
    /// a microphone, and a small rounded-hexagon face. The numbered circles that
    /// used to stand in for the bolt and the face were placeholders.
    ///
    /// `face.smiling` is the nearest available match rather than a real one — SF
    /// Symbols has no hexagonal face, so this trades the silhouette for the
    /// meaning. `mic` and `bolt` are the bare glyphs, not the `.circle` variants,
    /// because the reference draws them unenclosed while accept and reject are
    /// genuinely ringed; that difference is a real distinction on the cap and
    /// worth keeping.
    ///
    /// `selfCheckFailures()` resolves each name through `NSImage` rather than
    /// trusting this comment — the deployment target is macOS 14 and a symbol
    /// that arrived later would silently draw nothing.
    public static func iconName(for slot: PanelLayout.CommandSlot) -> String {
        switch slot {
        case .accept: "checkmark.circle"
        case .reject: "xmark.circle"
        case .newSession: "arrow.triangle.branch"
        case .pushToTalk: "mic"
        case .custom1: "bolt"
        case .custom2: "face.smiling"
        }
    }

    // MARK: - View

    public let slot: PanelLayout.CommandSlot
    public let layout: PanelLayout
    /// Capabilities of the session this cluster currently targets; `nil` when
    /// nothing is bound.
    public let capabilities: SessionCapabilities?
    public let canSpawnSessions: Bool
    public let action: (PanelLayout.CommandSlot) -> Void

    @FocusState.Binding var focusedSlot: PanelLayout.CommandSlot?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    @State private var isHovering = false

    public init(
        slot: PanelLayout.CommandSlot,
        layout: PanelLayout,
        capabilities: SessionCapabilities?,
        canSpawnSessions: Bool = true,
        focusedSlot: FocusState<PanelLayout.CommandSlot?>.Binding,
        action: @escaping (PanelLayout.CommandSlot) -> Void
    ) {
        self.slot = slot
        self.layout = layout
        self.capabilities = capabilities
        self.canSpawnSessions = canSpawnSessions
        self._focusedSlot = focusedSlot
        self.action = action
    }

    private var reason: String? {
        Self.unavailabilityReason(
            for: slot, capabilities: capabilities, canSpawnSessions: canSpawnSessions
        )
    }

    private var isEnabled: Bool {
        Self.isEnabled(slot, capabilities: capabilities, canSpawnSessions: canSpawnSessions)
    }

    public var body: some View {
        let reason = reason
        let enabled = isEnabled
        let size = layout.commandKeyFrame(slot).size

        // The tooltip hangs off the wrapper, not the Button: `.disabled` applies
        // to its subtree, and a hover explanation that vanishes exactly when the
        // key is unavailable would be worse than none.
        ZStack {
            Button { action(slot) } label: {
                face(enabled: enabled, size: size)
            }
            // Plain style so the frosted face shows; Button still handles Space
            // and Return itself when focused, which is why there is no manual
            // key handling here.
            .buttonStyle(.plain)
            // Focus decision: a disabled key is dropped from the keyboard focus
            // order (SwiftUI does this for a disabled Button), rather than kept
            // focusable and inert. Tabbing into a dead end on a six-key cluster
            // teaches nothing, and the "why" still reaches everyone: VoiceOver
            // visits it regardless of focusability, announces it as dimmed, and
            // reads the reason as its label. So nothing is hidden — only the Tab
            // path is kept to keys that do something.
            .disabled(!enabled)
            .focused($focusedSlot, equals: slot)
            .accessibilityLabel(reason ?? Self.actionName(for: slot))
        }
        .frame(width: size.width, height: size.height)
        .help(reason ?? Self.actionName(for: slot))
        .onHover { hovering in isHovering = hovering && enabled }
    }

    /// One thin line icon on an opaque cap. No caption: the reference caps carry
    /// nothing but the icon, and the words live in the tooltip and the VoiceOver
    /// label, which is where a disabled key's *reason* already lived.
    private func face(enabled: Bool, size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: layout.commandKeyCornerRadius, style: .continuous)
        let isFocused = focusedSlot == slot
        let lit = enabled && !reduceTransparency

        return Image(systemName: Self.iconName(for: slot))
            .font(.system(size: layout.fontSize(15), weight: .regular))
            // Only `.unassigned` of the seven palettes is specified as unlit and
            // recessed, which is what this cluster wants: measured-legible icon
            // on a face that reads quieter than any live agent key.
            .foregroundStyle(StateColors.keyLabel(.unassigned).opacity(enabled ? 0.9 : 0.42))
            .frame(width: size.width, height: size.height)
            .background {
                ZStack {
                    shape.fill(capBody(enabled: enabled))
                    if lit { shape.fill(gloss) }
                    // The dish. A real keycap's top face is concave, and that dish is
                    // most of what makes the reference photo read as an object rather
                    // than a rounded rectangle: a soft dark arc where the surface
                    // turns away from the light, and a highlight where it turns
                    // toward it. Inset well inside the cap so the icon still sits on
                    // flat, measured ground.
                    if lit, !reduceTransparency {
                        Circle()
                            .fill(
                                RadialGradient(
                                    stops: [
                                        .init(color: .black.opacity(0.045), location: 0.0),
                                        .init(color: .black.opacity(0.02), location: 0.55),
                                        .init(color: .clear, location: 0.78),
                                        .init(color: .white.opacity(0.55), location: 1.0),
                                    ],
                                    center: .init(x: 0.5, y: 0.42),
                                    startRadius: 0,
                                    endRadius: min(size.width, size.height) * 0.46
                                )
                            )
                            .padding(min(size.width, size.height) * 0.11)
                            .blur(radius: min(size.width, size.height) * 0.03)
                    }
                }
            }
            .overlay(edge(shape, enabled: enabled))
            .overlay {
                if isFocused {
                    shape.inset(by: -2 * layout.scale)
                        .strokeBorder(Color.accentColor, lineWidth: 2 * layout.scale)
                }
            }
            // Unlit caps cast no shadow, which is most of why they read as
            // pressed into the plate rather than sitting on it.
            .background { if lit { plateShadow(shape) } }
            .contentShape(shape)
            // Reduce Motion: the hover change still happens, it just arrives
            // instantly instead of easing.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }

    /// Bright white plastic, opaque. The reference command caps are the
    /// brightest thing on the device — brighter than the plate they sit on — and
    /// nothing in `StateColors` is white, because no *state* is white. So this
    /// one value is achromatic and local: hue stays the palette's monopoly.
    ///
    /// Only in the plain light appearance. On a dark panel a white cap glares,
    /// and under Increase Contrast the plate is pure white so a white cap would
    /// dissolve into it. Both fall back to `.unassigned`'s measured fill at full
    /// opacity, which is exactly where the icon's 4.5:1 was measured.
    ///
    /// Disabled drops to a translucent fill instead: the cap stops being a cap.
    private func capBody(enabled: Bool) -> Color {
        guard enabled else {
            return StateColors.keyFill(.unassigned).opacity(reduceTransparency ? 1 : 0.42)
        }
        if usesWhiteCap { return .white }
        return StateColors.keyFill(.unassigned)
    }

    private var usesWhiteCap: Bool {
        colorScheme == .light && colorSchemeContrast != .increased
    }

    /// The slight gloss of a moulded cap: nothing at the top face, shading down
    /// the lower bevel. Achromatic, and weak enough that the centre of the cap —
    /// where the icon sits — is left where `StateColors` measured it. Hover
    /// lifts the sheen a little; it is the only thing hover changes.
    private var gloss: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .white.opacity(isHovering ? 0.34 : 0.22), location: 0),
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.04), location: 0.7),
                .init(color: .black.opacity(0.13), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// Where the cap meets the plate. Its own blurred shape behind the key, not
    /// a `.shadow` on the fill, so a translucent disabled fill can never end up
    /// showing its own shadow through its face.
    private func plateShadow(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(.black.opacity(0.22))
            .blur(radius: 4 * layout.scale)
            .offset(y: 2.5 * layout.scale)
            .allowsHitTesting(false)
    }

    /// A solid hairline, enabled or not. The dashed border this replaced said
    /// "unfinished" far louder than it said "unavailable" — the honest signals
    /// for a dead key are the ones the hardware would give: no gloss, no
    /// shadow, a face sunk into the plate and a faded icon. Those survive
    /// greyscale and colour-blind vision without borrowing a placeholder motif,
    /// and the reason itself is still one hover or one VoiceOver stop away.
    private func edge(_ shape: RoundedRectangle, enabled: Bool) -> some View {
        let width = (reduceTransparency ? 1.5 : 0.75) * layout.scale
        return shape.strokeBorder(
            StateColors.keyEdge(.unassigned).opacity(enabled ? 0.45 : 0.28),
            lineWidth: width
        )
    }

    // MARK: - Self check

    /// Empty when healthy. Wired into `SelfCheck` by its owner.
    public static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        let slots = PanelLayout.CommandSlot.allCases

        // allCases, so adding a seventh slot fails here instead of shipping a
        // blank key with no capability gate.
        for slot in slots {
            let tag = slot.rawValue
            // The cap has no text on it, so the spoken name is the only name
            // there is. It cannot be empty.
            if actionName(for: slot).isEmpty { failures.append("\(tag) has no spoken action name") }

            let icon = iconName(for: slot)
            if icon.isEmpty {
                failures.append("\(tag) has no icon name")
            } else if NSImage(systemSymbolName: icon, accessibilityDescription: nil) == nil {
                failures.append("\(tag) icon \"\(icon)\" does not resolve as an SF Symbol")
            }

            if slot == .newSession {
                if requiredCapability(for: slot) != nil {
                    failures.append("newSession must not be gated on the bound session's capabilities")
                }
            } else if requiredCapability(for: slot) == nil {
                failures.append("\(tag) has no required capability")
            }
        }

        // With the caption gone the icon is the whole face, so two slots sharing
        // one would be two indistinguishable keys.
        for (index, first) in slots.enumerated() {
            for second in slots.dropFirst(index + 1) where iconName(for: first) == iconName(for: second) {
                failures.append(
                    "\(first.rawValue) and \(second.rawValue) share the icon \"\(iconName(for: first))\""
                )
            }
        }

        // The owned-vs-observed correction, stated as a check.
        for slot in [PanelLayout.CommandSlot.accept, .reject] where isEnabled(slot, capabilities: .observed) {
            failures.append("\(slot.rawValue) reports enabled on an observed session")
        }
        // newSession is the slot that does not read the bound session, so an
        // observed binding must not take it out.
        if !isEnabled(.newSession, capabilities: .observed) {
            failures.append("newSession reports disabled on an observed session")
        }
        if !isEnabled(.newSession, capabilities: nil) {
            failures.append("newSession reports disabled with no session bound")
        }
        // The observed reason text promises focus works. Keep it honest.
        if !SessionCapabilities.observed.contains(.focus) {
            failures.append("observed sessions cannot focus, so the disabled reason text lies")
        }
        for slot in slots where !isEnabled(slot, capabilities: .owned) {
            failures.append("\(slot.rawValue) reports disabled on an owned session")
        }

        // Enabled state and reason string must agree, always, and a disabled key
        // must never be silent about why.
        let matrix: [SessionCapabilities?] = [
            nil, SessionCapabilities([]), .observed, .owned, [.focus, .sendPrompt],
        ]
        for slot in slots {
            for capabilities in matrix {
                for canSpawn in [true, false] {
                    let enabled = isEnabled(slot, capabilities: capabilities, canSpawnSessions: canSpawn)
                    let reason = unavailabilityReason(
                        for: slot, capabilities: capabilities, canSpawnSessions: canSpawn
                    )
                    let caps = capabilities.map { "\($0.rawValue)" } ?? "unbound"
                    if enabled, reason != nil {
                        failures.append("\(slot.rawValue) is enabled but carries a reason (caps \(caps), spawn \(canSpawn))")
                    }
                    if !enabled, reason?.isEmpty ?? true {
                        failures.append("\(slot.rawValue) is disabled with no reason (caps \(caps), spawn \(canSpawn))")
                    }
                }
            }
        }

        // Positions come from PanelLayout and must stay one-per-slot. This also
        // catches `commandKeyFrame`'s `?? 0` fallback, which would silently
        // stack two slots on the same frame.
        for sizeClass in PanelLayout.SizeClass.allCases {
            let layout = PanelLayout(sizeClass: sizeClass)
            let tag = sizeClass.rawValue
            for (index, first) in slots.enumerated() {
                let a = layout.commandKeyFrame(first)
                if a.isEmpty {
                    failures.append("\(tag): \(first.rawValue) has an empty frame")
                }
                for second in slots[(index + 1)...] {
                    let b = layout.commandKeyFrame(second)
                    if a == b {
                        failures.append("\(tag): \(first.rawValue) and \(second.rawValue) share one frame")
                    } else if a.insetBy(dx: 0.01, dy: 0.01).intersects(b.insetBy(dx: 0.01, dy: 0.01)) {
                        failures.append("\(tag): \(first.rawValue) overlaps \(second.rawValue)")
                    }
                }
            }
        }

        return failures
    }
}

/// All six keys at their layout positions. Sized to the whole panel and using
/// absolute `.position`, per `PanelLayout`'s documented convention, so it drops
/// into the panel's `ZStack` beside the other zones.
public struct CommandKeyCluster: View {
    public let layout: PanelLayout
    public let capabilities: SessionCapabilities?
    public let canSpawnSessions: Bool
    public let action: (PanelLayout.CommandSlot) -> Void

    @FocusState private var focusedSlot: PanelLayout.CommandSlot?

    public init(
        layout: PanelLayout,
        capabilities: SessionCapabilities?,
        canSpawnSessions: Bool = true,
        action: @escaping (PanelLayout.CommandSlot) -> Void
    ) {
        self.layout = layout
        self.capabilities = capabilities
        self.canSpawnSessions = canSpawnSessions
        self.action = action
    }

    public var body: some View {
        ZStack {
            // Every slot, every time. A key that moved or vanished because a
            // capability changed would cost more than the click it saved.
            ForEach(PanelLayout.CommandSlot.allCases, id: \.self) { slot in
                let frame = layout.commandKeyFrame(slot)
                CommandKeyView(
                    slot: slot,
                    layout: layout,
                    capabilities: capabilities,
                    canSpawnSessions: canSpawnSessions,
                    focusedSlot: $focusedSlot,
                    action: action
                )
                .position(x: frame.midX, y: frame.midY)
            }
        }
        .frame(width: layout.panelSize.width, height: layout.panelSize.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command keys")
    }
}
