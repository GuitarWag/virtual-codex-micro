import SwiftUI

/// Composes the four zones into the control surface.
///
/// Absolute positioning from `PanelLayout` rather than stacks, deliberately: key
/// positions are the product's promise. A stack would let a label length change
/// move a key, and muscle memory dies the moment slot 3 drifts.
///
/// Two placement conventions coexist here and mixing them up is how the pad ended
/// up on top of the command cluster once. `CommandKeyCluster` is panel-sized and
/// positions its own children absolutely, so it takes no modifier. The dial and
/// pad size themselves to their zone and place their contents in zone-local
/// coordinates, so they take a top-left `.offset`. `.position` on either of those
/// double-places them.
struct PanelRootView: View {
    @ObservedObject var coordinator: PanelCoordinator
    let layout: PanelLayout

    /// The single cross-zone focus binding. Until this existed, `FocusOrder` was a
    /// well-checked model of a traversal that no view implemented — the a11y
    /// review's sharpest finding.
    @FocusState private var focus: FocusOrder.Target?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .topLeading) {
            silhouette
            agentKeys
            commandCluster
            dial
            pad
            overflowChip
        }
        .frame(width: layout.panelSize.width, height: layout.panelSize.height)
        // Panel-local Tab, wrapping rather than falling out of the last zone.
        .onKeyPress(.tab) { step(by: 1) }
        .onKeyPress(keys: [.tab], phases: .down) { press in
            press.modifiers.contains(.shift) ? step(by: -1) : .ignored
        }
    }

    private func step(by direction: Int) -> KeyPress.Result {
        guard let next = FocusOrder.step(
            from: focus, by: direction, in: FocusOrder.all, focusable: isFocusable
        ) else { return .ignored }
        focus = next
        return .handled
    }

    /// Delegates to each component's own rule rather than restating it, so a
    /// disabled command key or an unbound pad direction cannot be focusable here
    /// and inert there.
    private func isFocusable(_ target: FocusOrder.Target) -> Bool {
        switch target {
        case .agent, .dial:
            return true
        case .command(let slot):
            return CommandKeyView.isEnabled(
                slot, capabilities: coordinator.focusedCapabilities, canSpawnSessions: true
            )
        case .pad(let direction):
            return DirectionPadView.isActionable(
                direction, presets: DirectionPadView.defaultPresets { _ in }
            )
        }
    }

    // MARK: - Zones

    private var agentKeys: some View {
        ForEach(0 ..< PanelLayout.agentKeyCount, id: \.self) { index in
            let frame = layout.agentKeyFrame(index)
            AgentKeyView(
                index: index,
                state: coordinator.state(at: index),
                session: coordinator.session(at: index),
                layout: layout,
                onActivate: { coordinator.activateAgentKey(index) }
            )
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .focused($focus, equals: .agent(index))
            .onTapGesture(count: 1) { coordinator.activateAgentKey(index) }
            // Secondary click opens detail rather than acting, so the primary
            // gesture stays a single unambiguous thing.
            .contextMenu { Button("Session detail…") { coordinator.detailSlot = index } }
            .popover(
                isPresented: Binding(
                    get: { coordinator.detailSlot == index },
                    set: { if !$0 { coordinator.detailSlot = nil } }
                ),
                arrowEdge: .bottom
            ) {
                detailPopover(for: index)
            }
        }
    }

    @ViewBuilder
    private func detailPopover(for slot: Int) -> some View {
        if let resolution = coordinator.resolutions[slot] {
            SessionPopover(
                detail: SessionPopover.Detail(
                    slotIndex: slot,
                    session: coordinator.session(at: slot),
                    backendName: "Mock (demo)",
                    resolution: resolution
                ),
                layout: layout,
                onRebind: { coordinator.detailSlot = nil },
                onClear: { coordinator.detailSlot = nil },
                onOpenLog: { coordinator.detailSlot = nil }
            )
        }
    }

    private var commandCluster: some View {
        CommandKeyCluster(
            layout: layout,
            capabilities: coordinator.focusedCapabilities,
            canSpawnSessions: true,
            action: { coordinator.dispatch($0) }
        )
    }

    private var dial: some View {
        DialView(
            layout: layout,
            scale: .effort,
            stepIndex: Binding(
                get: { coordinator.effortStep },
                set: { coordinator.setEffort($0) }
            )
        )
        .offset(x: layout.dialFrame.minX, y: layout.dialFrame.minY)
        .focused($focus, equals: .dial)
    }

    private var pad: some View {
        DirectionPadView(
            layout: layout,
            presets: DirectionPadView.defaultPresets { _ in },
            openChooser: {}
        )
        .offset(x: layout.padZone.minX, y: layout.padZone.minY)
    }

    private var overflowChip: some View {
        OverflowView(
            unbound: coordinator.unbound,
            layout: layout,
            slotOccupants: (0 ..< PanelLayout.agentKeyCount).map { coordinator.session(at: $0)?.id },
            onBind: { _, _ in }
        )
        .offset(
            x: OverflowView.indicatorFrame(layout).minX,
            y: OverflowView.indicatorFrame(layout).minY
        )
    }

    /// Device-like frame rather than window chrome, per the visual requirements.
    private var silhouette: some View {
        RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
            .fill(reduceTransparency
                  ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                  : AnyShapeStyle(.ultraThinMaterial))
            .overlay(
                RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
                    .strokeBorder(.separator, lineWidth: reduceTransparency ? 1.5 : 0.5)
            )
            .frame(width: layout.panelSize.width, height: layout.panelSize.height)
    }
}
