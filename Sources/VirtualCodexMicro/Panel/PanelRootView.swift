import SwiftUI

/// Composes the four zones into the control surface. Until this existed, every
/// component was verified in isolation and the panel had never actually been
/// assembled — which is why the a11y audit could model an 18-stop focus order
/// but never walk it.
///
/// Absolute positioning from `PanelLayout` rather than stacks, deliberately: key
/// positions are the product's promise. A stack would let a label length change
/// move a key, and muscle memory dies the moment slot 3 drifts.
struct PanelRootView: View {
    let layout: PanelLayout
    /// Slot index → state. Missing means unassigned.
    var states: [Int: AgentState]
    var sessions: [Int: AgentSession]
    var capabilities: SessionCapabilities
    var canSpawnSessions: Bool
    var onAgentKey: (Int) -> Void
    var onCommand: (PanelLayout.CommandSlot) -> Void
    var onPreset: (PanelLayout.PadDirection) -> Void
    var onOpenChooser: () -> Void

    @State private var effortStep: Int = DialScale.effort.defaultIndex
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack(alignment: .topLeading) {
            silhouette

            ForEach(0..<PanelLayout.agentKeyCount, id: \.self) { index in
                let frame = layout.agentKeyFrame(index)
                AgentKeyView(
                    index: index,
                    state: states[index] ?? .unassigned,
                    session: sessions[index],
                    layout: layout,
                    onActivate: { onAgentKey(index) }
                )
                .frame(width: frame.width, height: frame.height)
                .position(x: frame.midX, y: frame.midY)
            }

            CommandKeyCluster(
                layout: layout,
                capabilities: capabilities,
                canSpawnSessions: canSpawnSessions,
                action: onCommand
            )

            // Dial and pad both size themselves from the layout and place their
            // contents in zone-local coordinates, so they take a top-left offset,
            // not `.position`. Using `.position` here double-placed the pad on top
            // of the command cluster — caught by the offscreen render, invisible to
            // every per-component check, because no component owns composition.
            DialView(layout: layout, scale: .effort, stepIndex: $effortStep)
                .offset(x: layout.dialFrame.minX, y: layout.dialFrame.minY)

            DirectionPadView(
                layout: layout,
                presets: DirectionPadView.defaultPresets { _ in },
                openChooser: onOpenChooser
            )
            .offset(x: layout.padZone.minX, y: layout.padZone.minY)
        }
        .frame(width: layout.panelSize.width, height: layout.panelSize.height)
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
