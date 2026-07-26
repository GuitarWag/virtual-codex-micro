import AppKit
import SwiftUI

/// The six fixed-purpose command keys: the quieter cluster next to the agent
/// keys. Icon plus short text label, no state glow, and a fill intensity well
/// below an agent key's — the agent keys carry the at-a-glance proposition and
/// must stay the brightest things on the panel.
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

    /// Text on the key. Short because the cap is 40pt at regular size, but never
    /// absent: an icon-only key is a guessing game for anyone who does not
    /// already know the cluster, and the spoken name lives in `actionName`.
    public static func keyLabel(for slot: PanelLayout.CommandSlot) -> String {
        switch slot {
        case .accept: "accept"
        case .reject: "reject"
        case .newSession: "new"
        case .pushToTalk: "talk"
        case .custom1: "c1"
        case .custom2: "c2"
        }
    }

    /// Spoken and hover name. Full words, unlike the cap.
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

    /// All six are SF Symbols 1.0 names, so they exist on every macOS the
    /// package supports (deployment target is macOS 14). `selfCheckFailures()`
    /// resolves each one through `NSImage` rather than trusting this comment.
    public static func iconName(for slot: PanelLayout.CommandSlot) -> String {
        switch slot {
        case .accept: "checkmark.circle"
        case .reject: "xmark.circle"
        case .newSession: "plus.circle"
        case .pushToTalk: "mic.circle"
        case .custom1: "1.circle"
        case .custom2: "2.circle"
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

    private func face(enabled: Bool, size: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: layout.commandKeyCornerRadius, style: .continuous)
        let isFocused = focusedSlot == slot

        return VStack(spacing: 1 * layout.scale) {
            Image(systemName: Self.iconName(for: slot))
                .font(.system(size: 14 * layout.scale, weight: .regular))
            Text(Self.keyLabel(for: slot))
                .font(.system(size: 8 * layout.scale, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        // Only `.unassigned` of the seven palettes is specified as unlit and
        // recessed, which is what this cluster wants: measured-legible label on
        // a face that reads quieter than any live agent key.
        .foregroundStyle(StateColors.keyLabel(.unassigned).opacity(enabled ? 1 : 0.55))
        .frame(width: size.width, height: size.height)
        .background(shape.fill(StateColors.keyFill(.unassigned).opacity(fillOpacity(enabled: enabled))))
        .overlay(edge(shape, enabled: enabled))
        .overlay {
            if isFocused {
                shape.inset(by: -2 * layout.scale)
                    .strokeBorder(Color.accentColor, lineWidth: 2 * layout.scale)
            }
        }
        .contentShape(shape)
        // Reduce Motion: the hover change still happens, it just arrives
        // instantly instead of easing.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }

    /// Enabled keys sit below every lit agent-key opacity (0.85 and up) so the
    /// cluster stays secondary. Reduce Transparency forces an opaque face —
    /// `.unassigned` clears 4.5:1 against its own undiluted fill in all four
    /// appearances, so going opaque costs no legibility.
    private func fillOpacity(enabled: Bool) -> Double {
        if reduceTransparency { return 1 }
        if !enabled { return 0.30 }
        return isHovering ? 0.62 : 0.50
    }

    /// Disabled keys get a dashed border. It survives greyscale, colour-blind
    /// vision and Increase Contrast, where a lower opacity alone might not, and
    /// it does not need a colour of its own.
    private func edge(_ shape: RoundedRectangle, enabled: Bool) -> some View {
        let width = (reduceTransparency ? 1.5 : 0.75) * layout.scale
        return shape.strokeBorder(
            StateColors.keyEdge(.unassigned).opacity(enabled ? 0.55 : 0.40),
            style: StrokeStyle(lineWidth: width, dash: enabled ? [] : [3 * layout.scale, 2 * layout.scale])
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
            if keyLabel(for: slot).isEmpty { failures.append("\(tag) has no key label") }
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
