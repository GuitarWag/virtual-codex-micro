import AppKit
import SwiftUI

// MARK: - Scale

/// The positions the dial can hold, with the words the user actually sees.
///
/// Injectable because an effort scale is a backend detail: Claude Code's
/// thinking levels and another provider's low/medium/high are not the same list,
/// and the dial has no business knowing which one it is showing. Labels are
/// semantic on purpose — a rotary that reports "2" tells a screen reader user
/// nothing, and the same is true of the tooltip.
public struct DialScale: Sendable, Equatable {

    /// Spoken name of the control, e.g. "Effort". Used as the accessibility
    /// label and the tooltip prefix.
    public let name: String

    /// Semantic labels, lowest travel first.
    public let labels: [String]

    /// Where `reset` lands. Documented default for `.effort` is index 1, "medium".
    public let defaultIndex: Int

    /// Sanitises rather than traps. A scale can arrive from an adapter, and a
    /// malformed effort list should degrade to a working dial instead of taking
    /// the panel down. Fewer than two usable labels is degenerate — there is
    /// nothing to rotate between — so it falls back.
    public init(name: String = "Effort", labels: [String], defaultIndex: Int) {
        let cleaned = labels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let usable = cleaned.count >= 2 ? cleaned : Self.fallbackLabels
        self.name = name.isEmpty ? "Effort" : name
        self.labels = usable
        self.defaultIndex = min(max(defaultIndex, 0), usable.count - 1)
    }

    static let fallbackLabels = ["low", "medium", "high"]

    public static let effort = DialScale(labels: fallbackLabels, defaultIndex: 1)

    public var stepCount: Int { labels.count }

    public func label(at index: Int) -> String {
        labels[DialGeometry.clamp(index, stepCount: stepCount)]
    }

    public var defaultLabel: String { label(at: defaultIndex) }
}

// MARK: - Angle maths

/// Pure geometry and stepping maths for the rotary. Deliberately free of any
/// view type so it can be exercised by `selfCheckFailures()` on a machine with
/// no test framework and no window server.
///
/// The load-bearing decision here is that rotation is tracked as *accumulated
/// signed delta*, never as absolute angle. Mapping absolute pointer angle to a
/// step looks simpler and is wrong: drag past 12 o'clock and the angle jumps
/// 359 → 1, which reads as a ~358° backwards sweep and slams the value from one
/// end of the scale to the other. Every pointer update instead contributes
/// `shortestDelta`, which is bounded to (-180, 180] and therefore cannot see the
/// seam at all.
public enum DialGeometry {

    /// Total travel from lowest to highest step, centred on 12 o'clock, so the
    /// ends sit at 7:30 and 4:30 like a physical knob with stops.
    public static let sweepDegrees: CGFloat = 270

    /// Pointer positions closer than this to the centre carry no usable angle;
    /// a few pixels of jitter there would otherwise spin the value.
    public static let deadZoneRadius: CGFloat = 6

    /// Horizontal travel per step for the sideways drag on the knob face.
    public static let horizontalPointsPerStep: CGFloat = 18

    /// Scroll travel per step. Also the multiplier for line-based wheels, so one
    /// detent on a mouse wheel is exactly one step.
    public static let scrollPointsPerStep: CGFloat = 12

    /// A step plus the sub-step travel banked toward the next one. Carrying the
    /// remainder is what makes slow dragging feel continuous instead of eating
    /// input below the step threshold.
    public struct Travel: Sendable, Equatable {
        public var index: Int
        public var accumulated: CGFloat

        public init(index: Int, accumulated: CGFloat = 0) {
            self.index = index
            self.accumulated = accumulated
        }
    }

    public static func clamp(_ index: Int, stepCount: Int) -> Int {
        min(max(index, 0), max(stepCount - 1, 0))
    }

    public static func degreesPerStep(stepCount: Int) -> CGFloat {
        guard stepCount > 1 else { return 0 }
        return sweepDegrees / CGFloat(stepCount - 1)
    }

    /// Where the pointer sits for a step: 0° is 12 o'clock, positive clockwise,
    /// matching SwiftUI's `rotationEffect` sign.
    public static func indicatorAngle(index: Int, stepCount: Int) -> CGFloat {
        guard stepCount > 1 else { return 0 }
        return -sweepDegrees / 2
            + CGFloat(clamp(index, stepCount: stepCount)) * degreesPerStep(stepCount: stepCount)
    }

    /// Clockwise angle of `point` about `center` in [0, 360), 0° at 12 o'clock.
    /// Nil inside the dead zone, where direction is noise.
    ///
    /// `-dy` because SwiftUI's y grows downward; without it the dial would turn
    /// the wrong way.
    public static func angle(of point: CGPoint, around center: CGPoint) -> CGFloat? {
        let dx = point.x - center.x
        let dy = point.y - center.y
        guard dx * dx + dy * dy >= deadZoneRadius * deadZoneRadius else { return nil }
        let degrees = atan2(dx, -dy) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }

    /// Signed shortest rotation from one angle to another, in (-180, 180]. This
    /// is the whole defence against the 0/360 seam.
    public static func shortestDelta(from: CGFloat, to: CGFloat) -> CGFloat {
        var delta = (to - from).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta <= -180 { delta += 360 }
        return delta
    }

    /// Applies signed travel and hands back the new step plus what is still
    /// banked. Shared by all three input paths — only `perStep` differs.
    ///
    /// At an end stop the banked remainder is dropped rather than kept. Keeping
    /// it would build wind-up debt: overshoot the top by five turns and the dial
    /// would ignore the first five turns back down, which no physical encoder
    /// does.
    public static func advance(
        _ travel: Travel,
        by delta: CGFloat,
        perStep: CGFloat,
        stepCount: Int
    ) -> Travel {
        guard perStep > 0, stepCount > 1, delta.isFinite, travel.accumulated.isFinite else {
            return Travel(index: clamp(travel.index, stepCount: stepCount))
        }
        let total = travel.accumulated + delta
        // Bounded before the Int conversion: a delta of 1e18 degrees is a bad
        // event, not a reason to trap on overflow.
        let whole = min(
            max((total / perStep).rounded(.towardZero), -CGFloat(stepCount)),
            CGFloat(stepCount)
        )
        guard abs(whole) >= 1 else {
            return Travel(index: clamp(travel.index, stepCount: stepCount), accumulated: total)
        }
        let target = clamp(travel.index, stepCount: stepCount) + Int(whole)
        let clamped = clamp(target, stepCount: stepCount)
        let remainder = clamped == target ? total - whole * perStep : 0
        return Travel(index: clamped, accumulated: remainder)
    }

    /// One pointer update of a rotational drag: previous angle to current angle.
    public static func rotate(
        _ travel: Travel,
        fromAngle: CGFloat,
        toAngle: CGFloat,
        stepCount: Int
    ) -> Travel {
        advance(
            travel,
            by: shortestDelta(from: fromAngle, to: toAngle),
            perStep: degreesPerStep(stepCount: stepCount),
            stepCount: stepCount
        )
    }
}

// MARK: - View

/// On-screen rotary encoder for the effort / reasoning scale.
///
/// Three pointer paths, because a circle is an awkward thing to trace with a
/// mouse and the control should not punish anyone for it: rotate the ring, drag
/// the knob face sideways, or scroll anywhere over the dial. Clicking the knob
/// resets to the scale's default. Arrow keys step, Home resets.
///
/// It has to read as a rotary rather than a bent slider, which is a visual claim
/// as much as an interaction one: the whole cap — its sliced face and its mark —
/// turns with the value, so the control visibly rotates instead of merely
/// sliding a dot around an arc.
///
/// ## Why it looks like this
///
/// The reference photographs in `docs/` show a short white cylindrical knob with
/// a diagonal slice taken off the top: one solid volume, a flat angled face
/// catching the light, a soft shadow on the plate, and no text anywhere on it.
/// An earlier version drew a large thin outlined circle with tick marks and the
/// current step's word printed across the middle, which at 46pt truncated to
/// "me..." and read as a debug widget. The word lives in the tooltip and the
/// accessibility value, which is where a 46pt knob can actually say it.
public struct DialView: View {

    private let layout: PanelLayout
    private let scale: DialScale
    @Binding private var stepIndex: Int

    /// Sub-step travel banked between pointer updates, in the unit of whichever
    /// path is active. Reset when a gesture ends so paths never inherit each
    /// other's leftovers.
    @State private var banked: CGFloat = 0
    @State private var lastAngle: CGFloat?
    @State private var lastHorizontal: CGFloat = 0
    @State private var scrollMonitor = ScrollWheelMonitor()
    @FocusState private var isFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Reduce Transparency: the a11y audit found this file rendered two materials
    // while reading neither setting, leaving the panel with two policies for one
    // requirement. AppKit's automatic NSVisualEffectView substitution may cover
    // it, but relying on that is untested and silent when it fails.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(layout: PanelLayout, scale: DialScale = .effort, stepIndex: Binding<Int>) {
        self.layout = layout
        self.scale = scale
        self._stepIndex = stepIndex
    }

    // Geometry comes from PanelLayout; the dial must not invent its own size or
    // the reset target stops matching the layout's hit-target sweep.
    private var diameter: CGFloat { layout.dialFrame.width }
    private var knobDiameter: CGFloat { layout.dialCenterFrame.width }
    private var center: CGPoint { CGPoint(x: diameter / 2, y: diameter / 2) }

    /// The drawn cap, a hair inside the cell so the drop shadow has room. The
    /// *hit* target stays `dialFrame`, so this cannot drift from the layout.
    private var capDiameter: CGFloat { diameter * 0.94 }

    /// How far the flat face reaches down the cap, and therefore how much of the
    /// cylinder the slice took off.
    private var faceDepth: CGFloat { capDiameter * 0.38 }

    /// Where the flat face points when the dial sits at 12 o'clock. Matches the
    /// photographs, which show the cut face up and to the left.
    private static let faceRestAngle: CGFloat = -35

    private var index: Int { DialGeometry.clamp(stepIndex, stepCount: scale.stepCount) }
    private var currentLabel: String { scale.label(at: index) }
    private var pointerAngle: CGFloat {
        DialGeometry.indicatorAngle(index: index, stepCount: scale.stepCount)
    }

    public var body: some View {
        ZStack {
            cap
            centreFace
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(rotationDrag)
        .overlay {
            Circle().strokeBorder(.tint, lineWidth: 2).opacity(isFocused ? 1 : 0)
        }
        .onHover { inside in
            if inside {
                scrollMonitor.start { points in scroll(by: points) }
            } else {
                scrollMonitor.stop()
            }
        }
        .focusable()
        .focused($isFocused)
        .onKeyPress(.upArrow) { step(by: 1) }
        .onKeyPress(.rightArrow) { step(by: 1) }
        .onKeyPress(.downArrow) { step(by: -1) }
        .onKeyPress(.leftArrow) { step(by: -1) }
        .onKeyPress(.home) { reset(); return .handled }
        .help("\(scale.name): \(currentLabel)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(scale.name)
        // The semantic word, never the index — the number is an implementation
        // detail and means nothing spoken aloud.
        .accessibilityValue(currentLabel)
        .accessibilityHint("Rotate the ring, drag the centre sideways, or scroll to change.")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: _ = step(by: 1)
            case .decrement: _ = step(by: -1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: Text("Reset to \(scale.defaultLabel)")) { reset() }
    }

    // MARK: Parts

    /// The knob: a solid pale cylinder, lit from the top left, sitting on its own
    /// shadow.
    ///
    /// `.white` and `.black` at low opacity are lighting, not colour: the real
    /// knob is white in both appearances, and shading it with `.primary` would
    /// invert the highlight in dark mode and make a lit volume read as a hole.
    /// Nothing here is state-coloured — the hardware encoder is not either.
    private var cap: some View {
        ZStack {
            Circle().fill(reduceTransparency
                ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                : AnyShapeStyle(.regularMaterial))
            Circle().fill(
                LinearGradient(
                    colors: [.white.opacity(0.5), .white.opacity(0.08), .black.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            slicedFace
            Circle().strokeBorder(.black.opacity(0.18), lineWidth: max(0.8, capDiameter * 0.018))
        }
        .frame(width: capDiameter, height: capDiameter)
        .shadow(color: .black.opacity(0.24), radius: capDiameter * 0.07,
                x: 0, y: capDiameter * 0.05)
    }

    /// The diagonal cut: the circular segment on one side of a chord, shaded a
    /// step darker than the crown, with the cut edge drawn crisply. The edge is
    /// what makes it read as a flat face rather than a smudge of shadow.
    ///
    /// Turns with the value — the flat side of a physical encoder is its position
    /// readout, which is why the mark below rides in the same rotating group.
    private var slicedFace: some View {
        // Half the chord, from the right triangle on the radius: the chord sits
        // `radius - faceDepth` from the centre.
        let radius = capDiameter / 2
        let offsetFromCentre = radius - faceDepth
        let chordWidth = 2 * (radius * radius - offsetFromCentre * offsetFromCentre).squareRoot()

        return ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [.black.opacity(0.26), .black.opacity(0.07)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: capDiameter, height: capDiameter)
                .mask(alignment: .top) { Rectangle().frame(height: faceDepth) }
            Rectangle()
                .fill(.black.opacity(0.34))
                .frame(width: chordWidth, height: max(0.8, capDiameter * 0.022))
                .offset(y: -radius + faceDepth)
            mark
        }
        .frame(width: capDiameter, height: capDiameter)
        .rotationEffect(.degrees(Self.faceRestAngle + pointerAngle))
        // Reduce Motion: snap. A spinning knob is exactly the kind of motion the
        // setting exists to suppress.
        .animation(reduceMotion ? nil : .interpolatingSpring(stiffness: 260, damping: 20),
                   value: index)
    }

    /// Position mark, on the crown opposite the cut so it stays on the lit face.
    private var mark: some View {
        Capsule()
            .fill(.black.opacity(0.40))
            .frame(width: max(1.5, capDiameter * 0.055), height: capDiameter * 0.13)
            .offset(y: capDiameter * 0.5 - capDiameter * 0.14)
    }

    /// The reset / sideways-drag region. Its size is `dialCenterFrame`, which
    /// `PanelLayout` publishes as a nested hit target — not ours to choose. Drawn
    /// as nothing: the reference knob has no inner disc, and the cap is one
    /// volume, not two stacked controls.
    private var centreFace: some View {
        Circle()
            .fill(.clear)
            .frame(width: knobDiameter, height: knobDiameter)
            .contentShape(Circle())
            .gesture(horizontalDrag)
    }

    // MARK: Input

    private var rotationDrag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                guard let angle = DialGeometry.angle(of: value.location, around: center) else {
                    return
                }
                defer { lastAngle = angle }
                guard let previous = lastAngle else { return }
                apply(
                    DialGeometry.rotate(
                        travel,
                        fromAngle: previous,
                        toAngle: angle,
                        stepCount: scale.stepCount
                    )
                )
            }
            .onEnded { _ in
                lastAngle = nil
                banked = 0
            }
    }

    private var horizontalDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let delta = value.translation.width - lastHorizontal
                lastHorizontal = value.translation.width
                apply(
                    DialGeometry.advance(
                        travel,
                        by: delta,
                        perStep: DialGeometry.horizontalPointsPerStep,
                        stepCount: scale.stepCount
                    )
                )
            }
            .onEnded { value in
                // A press that never moved is a click, and the knob's click is
                // reset. Handled here rather than with a separate tap gesture so
                // the two can never race.
                if abs(value.translation.width) < 3, abs(value.translation.height) < 3 {
                    reset()
                }
                lastHorizontal = 0
                banked = 0
            }
    }

    private func scroll(by points: CGFloat) {
        apply(
            DialGeometry.advance(
                travel,
                by: points,
                perStep: DialGeometry.scrollPointsPerStep,
                stepCount: scale.stepCount
            )
        )
    }

    private var travel: DialGeometry.Travel {
        DialGeometry.Travel(index: index, accumulated: banked)
    }

    private func apply(_ next: DialGeometry.Travel) {
        banked = next.accumulated
        if next.index != stepIndex { stepIndex = next.index }
    }

    private func step(by delta: Int) -> KeyPress.Result {
        banked = 0
        let next = DialGeometry.clamp(index + delta, stepCount: scale.stepCount)
        if next != stepIndex { stepIndex = next }
        return .handled
    }

    private func reset() {
        banked = 0
        if stepIndex != scale.defaultIndex { stepIndex = scale.defaultIndex }
    }

    // MARK: - Self check

    /// Empty when healthy. Wired into `SelfCheck` by the caller.
    ///
    /// Weighted toward the angle maths, because that is the part with a wrong
    /// implementation that looks right: `boundary`-tagged cases below all fail
    /// under absolute-angle mapping and pass under delta accumulation.
    public static func selfCheckFailures() -> [String] {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let scale = DialScale.effort
        let steps = scale.stepCount
        let perStep = DialGeometry.degreesPerStep(stepCount: steps)

        // --- scale integrity
        check("effort scale has \(steps) steps but \(scale.labels.count) labels",
              steps == scale.labels.count)
        check("effort scale labels must all be non-empty",
              scale.labels.allSatisfy { !$0.isEmpty })
        check("effort default index out of range",
              (0 ..< steps).contains(scale.defaultIndex))
        check("effort default must be medium, the documented reset target",
              scale.defaultLabel == "medium" && scale.defaultIndex == 1)
        check("label(at:) must clamp rather than trap",
              scale.label(at: -3) == "low" && scale.label(at: 99) == "high")

        let degenerate = DialScale(labels: ["  ", ""], defaultIndex: 7)
        check("a scale with no usable labels must fall back, not empty out",
              degenerate.stepCount == 3 && degenerate.defaultIndex == 2)

        // --- angle reading
        let c = CGPoint(x: 50, y: 50)
        check("12 o'clock must read 0 degrees",
              DialGeometry.angle(of: CGPoint(x: 50, y: 10), around: c) == 0)
        check("3 o'clock must read 90 degrees (clockwise positive)",
              DialGeometry.angle(of: CGPoint(x: 90, y: 50), around: c) == 90)
        check("6 o'clock must read 180 degrees",
              DialGeometry.angle(of: CGPoint(x: 50, y: 90), around: c) == 180)
        check("9 o'clock must read 270 degrees",
              DialGeometry.angle(of: CGPoint(x: 10, y: 50), around: c) == 270)
        check("the centre has no usable angle",
              DialGeometry.angle(of: c, around: c) == nil)

        // --- shortest delta stays inside half a turn, which is what makes the
        // seam invisible
        // Reported once rather than per pair: a broken implementation fails
        // hundreds of these and would bury every other line of output.
        var worstPair: (CGFloat, CGFloat, CGFloat)?
        for from in stride(from: CGFloat(0), to: 360, by: 7) {
            for to in stride(from: CGFloat(0), to: 360, by: 11) {
                let delta = DialGeometry.shortestDelta(from: from, to: to)
                if abs(delta) > 180, abs(delta) > abs(worstPair?.2 ?? 180) {
                    worstPair = (from, to, delta)
                }
            }
        }
        if let (from, to, delta) = worstPair {
            failures.append(
                "shortestDelta must stay inside half a turn; \(from) -> \(to) gave \(delta)"
            )
        }

        // --- boundary: the cases a naive absolute-angle dial gets wrong.
        // 350 -> 10 is a 20 degree nudge clockwise. Reading absolute angle, or
        // taking a raw `to - from`, sees -340 and drops two whole steps.
        let up = DialGeometry.rotate(
            DialGeometry.Travel(index: 1), fromAngle: 350, toAngle: 10, stepCount: steps
        )
        check("boundary: dragging 350->10 must nudge, not fall to the bottom step",
              up.index == 1 && abs(up.accumulated - 20) < 0.001)

        // Mirror image: 10 -> 350 is 20 degrees anticlockwise, and a raw
        // subtraction sees +340 and jumps to the top step.
        let down = DialGeometry.rotate(
            DialGeometry.Travel(index: 1), fromAngle: 10, toAngle: 350, stepCount: steps
        )
        check("boundary: dragging 10->350 must nudge, not jump to the top step",
              down.index == 1 && abs(down.accumulated + 20) < 0.001)

        // A full sweep walked in small increments straight through 12 o'clock
        // must arrive at the top step exactly once, having crossed the seam
        // mid-walk. Absolute-angle mapping ends up wherever the last angle
        // happens to point, which for 250 degrees is nowhere near the top.
        var walk = DialGeometry.Travel(index: 0)
        var angle: CGFloat = 340
        for _ in 0 ..< 27 {
            let next = (angle + 10).truncatingRemainder(dividingBy: 360)
            walk = DialGeometry.rotate(walk, fromAngle: angle, toAngle: next, stepCount: steps)
            angle = next
        }
        check("boundary: 270 degrees walked in 10 degree hops must reach the top step",
              walk.index == steps - 1)

        // Same walk backwards from the top returns to the bottom, so the seam is
        // not merely handled in one direction.
        var back = DialGeometry.Travel(index: steps - 1)
        angle = 20
        for _ in 0 ..< 27 {
            let next = (angle - 10 + 360).truncatingRemainder(dividingBy: 360)
            back = DialGeometry.rotate(back, fromAngle: angle, toAngle: next, stepCount: steps)
            angle = next
        }
        check("boundary: the same walk reversed must return to the bottom step",
              back.index == 0)

        // --- accumulated delta maps to the expected step
        let exact = DialGeometry.advance(
            DialGeometry.Travel(index: 0), by: perStep, perStep: perStep, stepCount: steps
        )
        check("one step of travel must move exactly one step",
              exact.index == 1 && abs(exact.accumulated) < 0.001)

        let short = DialGeometry.advance(
            DialGeometry.Travel(index: 0), by: perStep - 1, perStep: perStep, stepCount: steps
        )
        check("travel below one step must bank, not move or vanish",
              short.index == 0 && abs(short.accumulated - (perStep - 1)) < 0.001)

        let banked = DialGeometry.advance(
            short, by: 1, perStep: perStep, stepCount: steps
        )
        check("banked travel must complete the step",
              banked.index == 1 && abs(banked.accumulated) < 0.001)

        let twice = DialGeometry.advance(
            DialGeometry.Travel(index: 0), by: perStep * 2, perStep: perStep, stepCount: steps
        )
        check("two steps of travel must move two steps", twice.index == steps - 1)

        let negative = DialGeometry.advance(
            DialGeometry.Travel(index: 2), by: -perStep, perStep: perStep, stepCount: steps
        )
        check("negative travel must step down", negative.index == 1)

        // Scroll and horizontal drag ride the same accumulator; one detent and
        // one step of sideways travel must each be worth exactly one step.
        let scrolled = DialGeometry.advance(
            DialGeometry.Travel(index: 0),
            by: DialGeometry.scrollPointsPerStep,
            perStep: DialGeometry.scrollPointsPerStep,
            stepCount: steps
        )
        check("one scroll detent must move one step", scrolled.index == 1)
        let dragged = DialGeometry.advance(
            DialGeometry.Travel(index: 0),
            by: DialGeometry.horizontalPointsPerStep,
            perStep: DialGeometry.horizontalPointsPerStep,
            stepCount: steps
        )
        check("one step of horizontal travel must move one step", dragged.index == 1)

        // --- clamping at both ends, with no wind-up debt
        let pinnedTop = DialGeometry.advance(
            DialGeometry.Travel(index: steps - 1), by: perStep * 40, perStep: perStep, stepCount: steps
        )
        check("clamped at the top, and nothing banked past it",
              pinnedTop.index == steps - 1 && pinnedTop.accumulated == 0)
        let leavesTop = DialGeometry.advance(
            pinnedTop, by: -perStep, perStep: perStep, stepCount: steps
        )
        check("one step back off the top must move immediately, not repay overshoot",
              leavesTop.index == steps - 2)

        let pinnedBottom = DialGeometry.advance(
            DialGeometry.Travel(index: 0), by: -perStep * 40, perStep: perStep, stepCount: steps
        )
        check("clamped at the bottom, and nothing banked past it",
              pinnedBottom.index == 0 && pinnedBottom.accumulated == 0)
        let leavesBottom = DialGeometry.advance(
            pinnedBottom, by: perStep, perStep: perStep, stepCount: steps
        )
        check("one step off the bottom must move immediately",
              leavesBottom.index == 1)

        // Absurd input must clamp rather than trap on the Int conversion.
        let absurd = DialGeometry.advance(
            DialGeometry.Travel(index: 0), by: 1e18, perStep: perStep, stepCount: steps
        )
        check("an absurd delta must clamp, not overflow", absurd.index == steps - 1)
        let nonFinite = DialGeometry.advance(
            DialGeometry.Travel(index: 1), by: .nan, perStep: perStep, stepCount: steps
        )
        check("a non-finite delta must be ignored", nonFinite.index == 1)

        check("clamp must hold at both ends",
              DialGeometry.clamp(-5, stepCount: steps) == 0
                  && DialGeometry.clamp(99, stepCount: steps) == steps - 1)

        // --- indicator placement
        check("the bottom step must sit at one end of the sweep",
              DialGeometry.indicatorAngle(index: 0, stepCount: steps) == -DialGeometry.sweepDegrees / 2)
        check("the top step must sit at the other end",
              DialGeometry.indicatorAngle(index: steps - 1, stepCount: steps)
                  == DialGeometry.sweepDegrees / 2)
        check("the middle step of an odd scale must point at 12 o'clock",
              DialGeometry.indicatorAngle(index: 1, stepCount: 3) == 0)
        check("a single-step scale must not divide by zero",
              DialGeometry.degreesPerStep(stepCount: 1) == 0
                  && DialGeometry.indicatorAngle(index: 0, stepCount: 1) == 0)

        return failures
    }
}

// MARK: - Scroll wheel

/// Scroll wheel input, which SwiftUI does not expose on macOS 14.
///
/// A local event monitor, live only while the pointer is over the dial. The
/// obvious alternative — an `NSViewRepresentable` overlay overriding
/// `scrollWheel` — cannot work here: AppKit hit-tests real subviews ahead of the
/// hosting view's SwiftUI content, so that overlay would have to swallow or hand
/// back every mouse event and the two drag gestures underneath it would break.
private final class ScrollWheelMonitor {
    private var token: Any?

    func start(_ handler: @escaping @MainActor (CGFloat) -> Void) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // Read the scalars out here: NSEvent is not Sendable, so the event
            // itself must not cross into the isolated closure below.
            //
            // Line-based wheels report whole detents, trackpads report points.
            // Scaling the former keeps one detent worth exactly one step.
            let points = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * DialGeometry.scrollPointsPerStep
            // Local monitors are delivered on the main thread as part of normal
            // event dispatch; there is no other thread this can arrive on.
            if points != 0 { MainActor.assumeIsolated { handler(points) } }
            return event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    deinit { if let token { NSEvent.removeMonitor(token) } }
}
