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

/// The workflow launcher: **one** small round thumbstick you push in four
/// directions, where up, right, down and left each fire a preset and pressing the
/// centre opens the preset chooser.
///
/// ## Why it looks like this
///
/// The reference photographs in `docs/` show a single black round stick with a
/// shallow cross moulded into its cap, sitting in a slightly recessed square with
/// a dashed outline silkscreened around it. An earlier version drew four separate
/// outlined arrow keys plus a grid glyph in the middle, which the M1 review read
/// as cursor keys rather than a joystick — and it was also geometrically
/// impossible, since five 28pt targets do not fit in a 46pt cell.
///
/// Geometry comes entirely from `PanelLayout.padFrame(_:)`, which lays the five
/// regions out as the cardinal cells of a 3x3 grid and **leaves the four diagonal
/// cells inert**. That is a deliberate safety margin, not an oversight: a push
/// slipping between up and right lands on nothing and fires nothing, instead of
/// firing the neighbour the user did not mean. `PanelLayout` marks those regions
/// `nested`, the pointer path resolves them through the same pure
/// `direction(at:in:)` the layout publishes, and `selfCheckFailures()` probes the
/// diagonal cell centres to keep it that way.
///
/// The view sizes itself to `layout.padZone`, so the panel shell places it at
/// `padZone`'s origin in a ZStack over `panelBounds`.
///
/// ## One control, four actions
///
/// It is **one** focusable element, matching the single `FocusOrder.joystick`
/// stop and the single non-nested `joystick` hit target. Directions are not
/// separate stops, so they cannot be reached by Tab — which would be a dead end
/// for a screen-reader user if that were the only route. It is not: each bound
/// direction is published as a named accessibility action ("up, run review PR"),
/// so VoiceOver can trigger a specific direction directly, and the default action
/// opens the chooser.
///
/// Pointer: drag the stick and release over a direction. Keyboard: the arrow keys
/// push, Space and Return open the chooser. Arrows are safe to consume here
/// precisely *because* there is one stop — there is no internal focus for them to
/// move, so nothing gets trapped.
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

    /// How far the stick is currently pushed, in points. Follows the pointer while
    /// dragging and springs back on release.
    @State private var pushed: CGSize = .zero
    @FocusState private var isFocused: Bool
    /// Reduce Transparency: the a11y audit found this material ungated, leaving
    /// the panel with two policies for one requirement. AppKit's automatic
    /// NSVisualEffectView substitution might cover it, but that is untested and
    /// fails silently, so gate it explicitly like the key views already do.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        let plate = RoundedRectangle(cornerRadius: 7 * layout.scale, style: .continuous)
        return ZStack {
            recess(plate)
            stick
        }
        .frame(width: layout.padZone.width, height: layout.padZone.height)
        .contentShape(Rectangle())
        .gesture(pushDrag)
        .overlay {
            plate.strokeBorder(.tint, lineWidth: 2).opacity(isFocused ? 1 : 0)
        }
        .help(tooltip)
        .focusable()
        .focused($isFocused)
        .onKeyPress(.upArrow) { press(.up) }
        .onKeyPress(.rightArrow) { press(.right) }
        .onKeyPress(.downArrow) { press(.down) }
        .onKeyPress(.leftArrow) { press(.left) }
        .onKeyPress(.space) { press(.center) }
        .onKeyPress(.return) { press(.center) }
        // One element, because it is one control: five stops would contradict the
        // single `joystick` hit target and the single `FocusOrder` stop.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("workflow joystick")
        .accessibilityValue(boundSummary)
        .accessibilityHint("Push a direction to run its workflow, or activate to open the preset chooser.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activate(.center) }
        // The four directions, reachable without four focus stops. Derived from
        // `cardinals`, so a direction added to `PadDirection` gains its action
        // here without an edit, and an unbound direction is not offered at all —
        // an action that does nothing is worse than a missing one.
        .accessibilityActions {
            ForEach(Self.cardinals, id: \.self) { direction in
                if let preset = presets[direction] {
                    Button(accessibilityActionName(direction, preset: preset)) { preset.run() }
                }
            }
        }
    }

    // MARK: - The control

    /// The recessed square the stick sits in, with the printed dashed outline the
    /// photographs show silkscreened around it.
    private func recess(_ plate: RoundedRectangle) -> some View {
        ZStack {
            plate.fill(reduceTransparency
                ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                : AnyShapeStyle(.ultraThinMaterial))
            // Recessed, so the near edge is in shadow. `.black` at low opacity is
            // shading rather than colour; `.primary` would invert it in dark mode
            // and turn a dish into a dome.
            plate.fill(
                LinearGradient(
                    colors: [.black.opacity(0.14), .black.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            plate.strokeBorder(
                .primary.opacity(0.55),
                style: StrokeStyle(
                    lineWidth: max(1, 1.2 * layout.scale),
                    dash: [3 * layout.scale, 2.2 * layout.scale]
                )
            )
        }
        .frame(
            width: layout.padZone.width - 2 * layout.scale,
            height: layout.padZone.height - 2 * layout.scale
        )
    }

    /// The thumbstick: one dark round cap with a shallow moulded cross, lit from
    /// the top left and casting into the recess. Not state-coloured — the hardware
    /// stick is black whatever the agents are doing.
    private var stick: some View {
        let side = min(layout.padZone.width, layout.padZone.height) * 0.60
        return ZStack {
            Circle().fill(
                RadialGradient(
                    colors: [.black.opacity(0.74), .black.opacity(0.96)],
                    center: UnitPoint(x: 0.36, y: 0.30),
                    startRadius: 0,
                    endRadius: side * 0.75
                )
            )
            cross(side)
            Circle().strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.34), .white.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                lineWidth: max(0.8, side * 0.035)
            )
        }
        .frame(width: side, height: side)
        .shadow(color: .black.opacity(0.30), radius: side * 0.09, x: 0, y: side * 0.06)
        .offset(pushed)
        // Reduce Motion: the push still follows the pointer, but it snaps back
        // instead of springing.
        .animation(reduceMotion ? nil : .interpolatingSpring(stiffness: 320, damping: 18),
                   value: pushed)
    }

    /// The X moulded into the cap. Two crossing strokes, catching a little light.
    private func cross(_ side: CGFloat) -> some View {
        ForEach([45.0, -45.0], id: \.self) { angle in
            Capsule()
                .fill(.white.opacity(0.18))
                .frame(width: max(1, side * 0.055), height: side * 0.52)
                .rotationEffect(.degrees(angle))
        }
    }

    // MARK: - Input

    /// Drag the stick and release over a direction. Resolution goes through the
    /// same pure `direction(at:in:)` the layout publishes, so the inert diagonals
    /// are inert in the real pointer path and not merely in the check — a release
    /// in a corner fires nothing, and a release in the middle opens the chooser.
    private var pushDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let limit = min(layout.padZone.width, layout.padZone.height) * 0.11
                pushed = CGSize(
                    width: min(max(value.translation.width, -limit), limit),
                    height: min(max(value.translation.height, -limit), limit)
                )
            }
            .onEnded { value in
                pushed = .zero
                // `padFrame` is in panel coordinates; the gesture is in the view's.
                let point = CGPoint(
                    x: value.location.x + layout.padZone.minX,
                    y: value.location.y + layout.padZone.minY
                )
                if let target = Self.direction(at: point, in: layout) { activate(target) }
            }
    }

    /// Arrow keys push, Space and Return open the chooser. An unbound direction
    /// reports `.ignored` rather than swallowing the key, so the arrow still does
    /// whatever it would have done with this control absent.
    private func press(_ direction: PanelLayout.PadDirection) -> KeyPress.Result {
        guard Self.isActionable(direction, presets: presets) else { return .ignored }
        activate(direction)
        return .handled
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

    /// One tooltip, because there is one control. Lists what every direction is
    /// bound to, including the ones that are bound to nothing — a stick that will
    /// silently do nothing in one direction should say so on hover.
    private var tooltip: String {
        (Self.cardinals.map { direction in
            "\(direction.rawValue) — \(presets[direction]?.name ?? "no preset bound")"
        } + ["centre — open preset chooser"])
            .joined(separator: "\n")
    }

    /// Spoken value: what this one control currently launches. Names presets, not
    /// positions — "up" alone tells a VoiceOver user where to push and nothing
    /// about what happens next.
    private var boundSummary: String {
        let bound = Self.cardinals.compactMap { direction in
            presets[direction].map { "\(direction.rawValue), \($0.name)" }
        }
        return bound.isEmpty ? "no presets bound" : bound.joined(separator: "; ")
    }

    /// Exhaustive on purpose: a new `PadDirection` breaks the build here, which is
    /// a louder failure than an unnamed action shipping unnoticed.
    private func accessibilityActionName(
        _ direction: PanelLayout.PadDirection,
        preset: WorkflowPreset
    ) -> String {
        switch direction {
        case .up, .right, .down, .left: "\(direction.rawValue), run \(preset.name)"
        case .center: "open preset chooser"
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
