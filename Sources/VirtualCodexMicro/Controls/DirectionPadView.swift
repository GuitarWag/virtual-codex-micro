import CoreGraphics
import SwiftUI

/// A workflow the pad can launch. `name` is the only user-visible string — hover
/// tooltip and VoiceOver both read it — and `run` is what fires on click, Space
/// or Return.
///
/// Not `Sendable` on purpose: it holds a UI closure and never leaves the main
/// actor. If a preset ever needs to be handed to a background task, wrap the
/// call site rather than loosening this.
public struct WorkflowPreset {
    public let name: String
    public let run: () -> Void

    public init(name: String, run: @escaping () -> Void) {
        self.name = name
        self.run = run
    }
}

/// The four-direction workflow launcher: a planar pad where up, right, down and
/// left each fire a preset and the centre opens the preset chooser.
///
/// Geometry comes entirely from `PanelLayout.padFrame(_:)`, which lays the five
/// live targets out as the cardinal cells of a 3x3 grid and **leaves the four
/// diagonal cells inert**. That is a deliberate safety margin, not an oversight:
/// a pointer slipping between up and right lands on nothing and fires nothing,
/// instead of firing the neighbour the user did not mean. Nothing here routes a
/// diagonal to a neighbour, and `selfCheckFailures()` probes the diagonal cell
/// centres to keep it that way.
///
/// The view sizes itself to `layout.padZone`, so the panel shell places it with
/// `.position(x: padZone.midX, y: padZone.midY)` in a ZStack over `panelBounds`.
///
/// ## Keyboard
///
/// Every live target is individually focusable, so Tab walks into the pad rather
/// than skipping it or treating it as one opaque control. Tab order follows
/// `PanelLayout.PadDirection.allCases` — up, right, down, left, then centre,
/// i.e. clockwise from the top and the chooser last. That matches the order
/// `PanelLayout.hitTargets` publishes for the pad zone, so the documented panel
/// traversal order and the real focus order cannot drift apart. Shift-Tab walks
/// back out the same way. The focused cell draws an accent ring, and Space or
/// Return activates it. Unbound directions are removed from the focus chain
/// entirely, so Tab never parks on a key that would do nothing.
///
/// Arrow keys are deliberately *not* activation keys here: they are how focus
/// moves inside a SwiftUI focus group, and stealing them would trap focus in the
/// pad. Direction is expressed by which cell you focus, not by which arrow you
/// press.
public struct DirectionPadView: View {

    // Everything in this section is `nonisolated`. `View` conformance infers
    // `@MainActor` on the whole type, which would make the pure geometry and
    // binding logic unreachable from off the main actor — including from
    // `SelfCheck.run()`, which is nonisolated. These functions touch no state
    // and no UI, so isolating them buys nothing and costs testability.

    /// The launchable directions, derived from the enum rather than listed, so a
    /// direction added to `PanelLayout.PadDirection` becomes a real target here
    /// without an edit. Everything except the centre, which opens the chooser.
    public nonisolated static var cardinals: [PanelLayout.PadDirection] {
        PanelLayout.PadDirection.allCases.filter { $0 != .center }
    }

    /// The documented default preset set. These four are the example workflows
    /// from the PRD, kept out of the view body so a caller can replace them
    /// wholesale — the view never reads them except through `presets`.
    public nonisolated static let defaultPresetNames: [PanelLayout.PadDirection: String] = [
        .up: "review PR",
        .right: "debug issue",
        .down: "explain code",
        .left: "write docs",
    ]

    /// Default bindings, with one dispatch closure for all four. Suits the
    /// common case where a caller routes every preset through the same launcher;
    /// build the dictionary by hand for per-preset behaviour.
    public nonisolated static func defaultPresets(
        run: @escaping (String) -> Void
    ) -> [PanelLayout.PadDirection: WorkflowPreset] {
        defaultPresetNames.mapValues { name in
            WorkflowPreset(name: name) { run(name) }
        }
    }

    /// Pure hit test: which target, if any, owns `point` in panel coordinates.
    /// Returns `nil` for the four diagonal cells and for anything outside the
    /// pad. No UI, no state — the inert-diagonal guarantee is checkable from a
    /// unit check because this function is the only thing that decides it.
    public nonisolated static func direction(
        at point: CGPoint,
        in layout: PanelLayout
    ) -> PanelLayout.PadDirection? {
        PanelLayout.PadDirection.allCases.first { layout.padFrame($0).contains(point) }
    }

    /// The centre is always live (it opens the chooser); a cardinal is live only
    /// while something is bound to it.
    public nonisolated static func isActionable(
        _ direction: PanelLayout.PadDirection,
        presets: [PanelLayout.PadDirection: WorkflowPreset]
    ) -> Bool {
        direction == .center || presets[direction] != nil
    }

    private let layout: PanelLayout
    private let presets: [PanelLayout.PadDirection: WorkflowPreset]
    private let openChooser: () -> Void

    @State private var hovered: PanelLayout.PadDirection?
    @FocusState private var focused: PanelLayout.PadDirection?

    /// - Parameters:
    ///   - presets: direction to preset. Any entry for `.center` is ignored —
    ///     the centre is the chooser. Missing directions render as unbound.
    ///   - openChooser: fired by the centre target.
    public init(
        layout: PanelLayout = .regular,
        presets: [PanelLayout.PadDirection: WorkflowPreset],
        openChooser: @escaping () -> Void
    ) {
        self.layout = layout
        self.presets = presets
        self.openChooser = openChooser
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(PanelLayout.PadDirection.allCases, id: \.self, content: cell)
        }
        .frame(width: layout.padZone.width, height: layout.padZone.height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("workflow pad")
    }

    // MARK: - One target

    @ViewBuilder
    private func cell(_ direction: PanelLayout.PadDirection) -> some View {
        let frame = layout.padFrame(direction)
        let live = Self.isActionable(direction, presets: presets)
        let shape = RoundedRectangle(cornerRadius: 6 * layout.scale, style: .continuous)
        let highlighted = live && hovered == direction

        let base = ZStack {
            // Unbound reads as a hole, not a key: flat quaternary fill, dashed
            // edge, dimmed glyph. A key that looks live and does nothing is
            // worse than one that looks empty.
            shape.fill(live ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(.quaternary))
            shape.fill(Color.accentColor.opacity(highlighted ? 0.18 : 0))
            shape.strokeBorder(
                live ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary),
                style: StrokeStyle(lineWidth: 1, dash: live ? [] : [3, 2])
            )
            Image(systemName: glyph(direction))
                .font(.system(size: 13 * layout.scale, weight: .medium))
                .foregroundStyle(live ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
        }
        .overlay {
            shape
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .opacity(focused == direction ? 1 : 0)
        }
        .frame(width: frame.width, height: frame.height)
        .contentShape(shape)
        .offset(x: frame.minX - layout.padZone.minX, y: frame.minY - layout.padZone.minY)
        // Hover reveals what the key is bound to. An unbound key still answers
        // the hover, saying why nothing will happen.
        .help(tooltip(direction))
        .onHover { inside in
            if inside {
                hovered = direction
            } else if hovered == direction {
                hovered = nil
            }
        }
        .onTapGesture { activate(direction) }
        .focusable(live)
        .focused($focused, equals: direction)
        .onKeyPress(.space) { activate(direction); return .handled }
        .onKeyPress(.return) { activate(direction); return .handled }
        .accessibilityElement()
        .accessibilityLabel(accessibilityLabel(direction))

        // VoiceOver must be told what the key *does*, and must not be offered an
        // action that does nothing, so the button trait and the action go on
        // together or not at all.
        if live {
            base
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { activate(direction) }
        } else {
            base
        }
    }

    // MARK: - Behaviour

    private func activate(_ direction: PanelLayout.PadDirection) {
        guard Self.isActionable(direction, presets: presets) else { return }
        if direction == .center {
            openChooser()
        } else {
            presets[direction]?.run()
        }
    }

    // MARK: - Copy

    private func tooltip(_ direction: PanelLayout.PadDirection) -> String {
        if direction == .center { return "centre — open preset chooser" }
        guard let preset = presets[direction] else {
            return "\(direction.rawValue) — no preset bound"
        }
        return "\(direction.rawValue) — \(preset.name)"
    }

    /// Names the preset, not the position. "up" alone tells a VoiceOver user
    /// where the key is and nothing about what it does.
    private func accessibilityLabel(_ direction: PanelLayout.PadDirection) -> String {
        if direction == .center { return "centre, open preset chooser" }
        guard let preset = presets[direction] else {
            return "\(direction.rawValue), no preset bound"
        }
        return "\(direction.rawValue), run \(preset.name)"
    }

    /// Exhaustive on purpose: a new `PadDirection` breaks the build here, which
    /// is a louder failure than a placeholder glyph shipping unnoticed.
    private func glyph(_ direction: PanelLayout.PadDirection) -> String {
        switch direction {
        case .up: "arrow.up"
        case .right: "arrow.right"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .center: "square.grid.2x2"
        }
    }

    // MARK: - Invariants

    /// Empty means healthy. Wired into `SelfCheck` by the caller.
    public nonisolated static func selfCheckFailures() -> [String] {
        let epsilon: CGFloat = 0.01
        var failures: [String] = []

        // Bindings: the default set must cover every launchable direction, and
        // must leave the centre alone.
        let defaults = defaultPresets { _ in }
        for target in cardinals {
            guard let preset = defaults[target] else {
                failures.append("default preset set has no workflow for \(target.rawValue)")
                continue
            }
            if preset.name.isEmpty {
                failures.append("default preset for \(target.rawValue) has an empty name")
            }
        }
        if defaults[.center] != nil {
            failures.append("centre carries a preset; it must open the chooser instead")
        }

        // Actionability: unbound must report dead, bound must report live, and
        // the centre must stay live with no presets at all.
        for target in cardinals {
            var unbound = defaults
            unbound[target] = nil
            if isActionable(target, presets: unbound) {
                failures.append("unbound \(target.rawValue) reports as actionable")
            }
            if !isActionable(target, presets: defaults) {
                failures.append("bound \(target.rawValue) reports as non-actionable")
            }
        }
        if !isActionable(.center, presets: [:]) {
            failures.append("centre reports as non-actionable with no presets bound")
        }

        for sizeClass in PanelLayout.SizeClass.allCases {
            let layout = PanelLayout(sizeClass: sizeClass)
            let tag = sizeClass.rawValue
            let zone = layout.padZone
            let cell = zone.width / 3

            // Geometry: iterate allCases so a direction added later cannot be
            // silently unplaced.
            var placed: [CGRect] = []
            for target in PanelLayout.PadDirection.allCases {
                let frame = layout.padFrame(target)
                if frame.isEmpty {
                    failures.append("\(tag): \(target.rawValue) has no frame from PanelLayout")
                }
                if !zone.insetBy(dx: -epsilon, dy: -epsilon).contains(frame) {
                    failures.append("\(tag): \(target.rawValue) frame escapes the pad zone")
                }
                if placed.contains(frame) {
                    failures.append("\(tag): \(target.rawValue) shares a frame with another direction")
                }
                placed.append(frame)

                // A cell centre must hit-test back to its own direction. Without
                // this the diagonal check below could pass for the wrong reason
                // — a hit test that always returns nil satisfies it trivially.
                let centre = CGPoint(x: frame.midX, y: frame.midY)
                if direction(at: centre, in: layout) != target {
                    failures.append("\(tag): centre of \(target.rawValue) does not hit-test to itself")
                }
            }

            // The inert-diagonal guarantee, exercised rather than asserted: the
            // centre of each of the four corner cells is a point comfortably
            // inside the pad zone, and every one of them must resolve to no
            // direction at all.
            for (column, row) in [(0, 0), (2, 0), (0, 2), (2, 2)] {
                let point = CGPoint(
                    x: zone.minX + (CGFloat(column) + 0.5) * cell,
                    y: zone.minY + (CGFloat(row) + 0.5) * cell
                )
                if !zone.contains(point) {
                    failures.append("\(tag): diagonal probe (\(column),\(row)) is outside the pad zone")
                }
                if let hit = direction(at: point, in: layout) {
                    failures.append(
                        "\(tag): diagonal cell (\(column),\(row)) resolved to \(hit.rawValue); diagonals must be inert"
                    )
                }
            }
        }

        return failures
    }
}
