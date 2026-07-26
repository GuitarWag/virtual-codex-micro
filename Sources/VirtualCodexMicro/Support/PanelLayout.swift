import CoreGraphics
import Foundation

/// Geometry for the control surface. Single source of truth: every view reads
/// positions from here, so a spacing change never means editing six view files.
///
/// ## Why this is one grid and not four zones
///
/// An earlier version of this file laid out four separately-placed clusters, which
/// is what the PRD's "four zones" language implies. The reference photographs in
/// `docs/` show that is wrong: the real device is a single uniform **4x4 grid** on
/// a square plate, with the rotary encoder occupying the top-left cell and the
/// joystick the top-right cell — both *inside* the grid, not beside it.
///
/// ```
///   [encoder] [agent 0] [agent 1] [joystick]
///   [agent 2] [agent 3] [agent 4] [agent 5]
///   [bolt]    [accept]  [reject]  [branch]
///   [status]  [---- mic 2u ----]  [face]
/// ```
///
/// Consequences worth knowing before editing:
///
/// - **Zones are logical, not spatial.** `agentZone` is the bounding box of six
///   keys that straddle two rows, so it necessarily contains the encoder and
///   joystick cells. Zone-versus-zone overlap is therefore no longer an invariant
///   and the self-check does not assert it. The invariant that matters — and is
///   asserted — is that no two *interactive targets* overlap.
/// - **The joystick is one control, not five keys.** Five 28pt targets do not fit
///   in a 46pt cell. `padFrame(_:)` returns gesture sub-regions for direction
///   hit-testing, and those are marked `nested` so they are exempt from the hit
///   floor; the stick itself is the single focusable target. That matches the
///   hardware, where you push one stick rather than press four caps.
public struct PanelLayout: Sendable, Equatable {

    // MARK: - Size class

    public enum SizeClass: String, CaseIterable, Sendable {
        case regular, compact

        public var scale: CGFloat {
            switch self {
            case .regular: 1
            case .compact: max(PanelLayout.requestedCompactScale, PanelLayout.minimumScale)
            }
        }
    }

    public enum Zone: String, CaseIterable, Sendable {
        case agents, commands, dial, pad, status
    }

    /// The six command positions, in grid order: the bolt, accept, reject and
    /// branch keys across row 3, then the wide microphone and the face key.
    public enum CommandSlot: String, CaseIterable, Sendable {
        case custom1, accept, reject, newSession, pushToTalk, custom2
    }

    public enum PadDirection: String, CaseIterable, Sendable {
        case up, right, down, left, center
    }

    public struct HitTarget: Sendable, Equatable {
        public let name: String
        public let frame: CGRect
        public let zone: Zone
        /// Exempt from the hit-size floor and the overlap sweep: a region inside
        /// another target rather than a target of its own.
        public let nested: Bool

        public init(name: String, frame: CGRect, zone: Zone, nested: Bool = false) {
            self.name = name
            self.frame = frame
            self.zone = zone
            self.nested = nested
        }
    }

    // MARK: - Base geometry, in points at regular size

    public static let agentKeyCount = 8
    public static let columns = 4
    public static let rows = 4

    /// Chunky, keycap-like. The reference device reads as a dense grid of large
    /// caps with hairline gaps, not small buttons floating in space.
    static let unit: CGFloat = 46
    static let gap: CGFloat = 6
    static let step: CGFloat = unit + gap

    /// Room for the vertical side legends on the plate.
    static let plateInsetX: CGFloat = 26
    /// Top carries the orientation arrow, bottom the "Let's build" legend.
    static let plateInsetTop: CGFloat = 20
    static let plateInsetBottom: CGFloat = 26
    /// The translucent shell around the plate.
    static let caseInset: CGFloat = 13
    /// Transparent margin around the shell so the state underglow can bleed
    /// outside the device the way the reference photographs show. Without it the
    /// glow would be clipped at the case edge and the whole at-a-glance effect —
    /// which is ambient light spilling onto the desk, not a lit key — is lost.
    static let glowBleed: CGFloat = 22

    public static let minimumHitTarget: CGFloat = 28

    /// Floor for any label rendered on the panel. The a11y audit measured real
    /// label sizes of 6.40–8.00pt once the compact scale was applied, which is
    /// below what is readable at a glance — and glanceability is the product.
    public static let minimumFontSize: CGFloat = 9

    /// Derived, not chosen: shrinking the panel clamps here rather than producing
    /// a sub-28pt key.
    static let minimumScale: CGFloat = minimumHitTarget / unit
    static let requestedCompactScale: CGFloat = 0.8

    public let sizeClass: SizeClass
    public init(sizeClass: SizeClass) { self.sizeClass = sizeClass }
    public static let regular = PanelLayout(sizeClass: .regular)
    public static let compact = PanelLayout(sizeClass: .compact)

    public var scale: CGFloat { sizeClass.scale }

    private func s(_ value: CGFloat) -> CGFloat { value * scale }

    // MARK: - Panel and plate

    var gridSize: CGFloat {
        s(CGFloat(Self.columns) * Self.unit + CGFloat(Self.columns - 1) * Self.gap)
    }

    /// The shell itself, inset from the panel by the glow bleed.
    public var caseFrame: CGRect {
        CGRect(
            x: s(Self.glowBleed), y: s(Self.glowBleed),
            width: plateFrame.width + s(Self.caseInset * 2),
            height: plateFrame.height + s(Self.caseInset * 2)
        )
    }

    public var plateFrame: CGRect {
        CGRect(
            x: s(Self.glowBleed + Self.caseInset), y: s(Self.glowBleed + Self.caseInset),
            width: gridSize + s(Self.plateInsetX * 2),
            height: gridSize + s(Self.plateInsetTop + Self.plateInsetBottom)
        )
    }

    public var panelSize: CGSize {
        CGSize(
            width: plateFrame.width + s((Self.caseInset + Self.glowBleed) * 2),
            height: plateFrame.height + s((Self.caseInset + Self.glowBleed) * 2)
        )
    }

    public var panelBounds: CGRect { CGRect(origin: .zero, size: panelSize) }

    /// The shell is a soft squarish blob, close to a squircle.
    public var cornerRadius: CGFloat { s(34) }
    public var plateCornerRadius: CGFloat { s(24) }
    public var agentKeyCornerRadius: CGFloat { s(10) }
    public var commandKeyCornerRadius: CGFloat { s(10) }

    private var gridOrigin: CGPoint {
        CGPoint(x: plateFrame.minX + s(Self.plateInsetX), y: plateFrame.minY + s(Self.plateInsetTop))
    }

    /// One grid cell, optionally spanning more than one column.
    func cell(row: Int, column: Int, columnSpan: Int = 1) -> CGRect {
        CGRect(
            x: gridOrigin.x + CGFloat(column) * s(Self.step),
            y: gridOrigin.y + CGFloat(row) * s(Self.step),
            width: s(Self.unit) * CGFloat(columnSpan) + s(Self.gap) * CGFloat(columnSpan - 1),
            height: s(Self.unit)
        )
    }

    // MARK: - Agent keys

    /// Both top rows, in reading order.
    ///
    /// The reference device spends its two top-corner cells on a rotary encoder and
    /// a joystick, and this layout followed it. Neither earned the space: the
    /// encoder's value was never dispatched anywhere, and the pad shipped with all
    /// four presets unbound. Two dead controls cost two agent slots, and agent slots
    /// are the entire product — so the corners became keys 0 and 3.
    ///
    /// This is a deliberate departure from hardware fidelity. `dialFrame` and
    /// `padZone` still compute so `DialView` and `DirectionPadView` keep compiling
    /// with their checks intact, but nothing composes them and they are absent from
    /// `hitTargets`.
    private static let agentCells: [(row: Int, column: Int)] = [
        (0, 0), (0, 1), (0, 2), (0, 3),
        (1, 0), (1, 1), (1, 2), (1, 3),
    ]

    public var agentKeyFrames: [CGRect] {
        Self.agentCells.map { cell(row: $0.row, column: $0.column) }
    }

    /// Traps on a bad index rather than returning `.zero`: a zero frame would draw
    /// a key silently at the panel origin.
    public func agentKeyFrame(_ index: Int) -> CGRect {
        precondition(Self.agentCells.indices.contains(index), "agent key index \(index) out of range")
        let position = Self.agentCells[index]
        return cell(row: position.row, column: position.column)
    }

    // MARK: - Command keys

    private static func commandCell(_ slot: CommandSlot) -> (row: Int, column: Int, span: Int) {
        switch slot {
        case .custom1: (2, 0, 1)
        case .accept: (2, 1, 1)
        case .reject: (2, 2, 1)
        case .newSession: (2, 3, 1)
        case .pushToTalk: (3, 1, 2)   // the wide microphone key
        case .custom2: (3, 3, 1)
        }
    }

    public func commandKeyFrame(_ slot: CommandSlot) -> CGRect {
        let position = Self.commandCell(slot)
        return cell(row: position.row, column: position.column, columnSpan: position.span)
    }

    public var commandKeyFrames: [CGRect] { CommandSlot.allCases.map(commandKeyFrame) }

    /// Bottom-left cell: status LEDs and the small round button. Not a command
    /// slot — it is an indicator cluster, and nothing dispatches from it.
    public var statusClusterFrame: CGRect { cell(row: 3, column: 0) }

    // MARK: - Encoder and joystick

    public var dialFrame: CGRect { cell(row: 0, column: 0) }

    /// The encoder's flat top. Concentric inside `dialFrame`, so it is nested.
    public var dialCenterFrame: CGRect {
        dialFrame.insetBy(dx: dialFrame.width * 0.28, dy: dialFrame.height * 0.28)
    }

    public var padZone: CGRect { cell(row: 0, column: 3) }

    /// Gesture regions inside the single stick, not keys. A 46pt cell cannot hold
    /// five 28pt targets, so these are `nested` and exempt from the floor; the
    /// stick itself is the focusable target.
    public func padFrame(_ direction: PadDirection) -> CGRect {
        let third = padZone.width / 3
        switch direction {
        case .up: return CGRect(x: padZone.minX + third, y: padZone.minY, width: third, height: third)
        case .down: return CGRect(x: padZone.minX + third, y: padZone.maxY - third, width: third, height: third)
        case .left: return CGRect(x: padZone.minX, y: padZone.minY + third, width: third, height: third)
        case .right: return CGRect(x: padZone.maxX - third, y: padZone.minY + third, width: third, height: third)
        case .center: return padZone.insetBy(dx: third, dy: third)
        }
    }

    public var padTargetFrames: [(direction: PadDirection, frame: CGRect)] {
        PadDirection.allCases.map { ($0, padFrame($0)) }
    }

    // MARK: - Zones

    /// Bounding boxes of logical groups. These overlap by construction — the agent
    /// keys straddle two rows and therefore enclose the encoder and joystick cells.
    /// See the type comment; zone disjointness is not an invariant here.
    public func zoneFrame(_ zone: Zone) -> CGRect {
        switch zone {
        case .agents: agentKeyFrames.reduce(CGRect.null) { $0.union($1) }
        case .commands: commandKeyFrames.reduce(CGRect.null) { $0.union($1) }
        case .dial: dialFrame
        case .pad: padZone
        case .status: statusClusterFrame
        }
    }

    public var agentZone: CGRect { zoneFrame(.agents) }
    public var commandZone: CGRect { zoneFrame(.commands) }
    public var dialZone: CGRect { zoneFrame(.dial) }
    public var zoneFrames: [(zone: Zone, frame: CGRect)] { Zone.allCases.map { ($0, zoneFrame($0)) } }

    // MARK: - Hit targets

    /// Every interactive element, in traversal order.
    ///
    /// The encoder and joystick are deliberately absent: their cells are agent keys
    /// 0 and 3 now. `dialFrame` and `padZone` still compute, so `DialView` and
    /// `DirectionPadView` keep compiling with their own checks intact, but they are
    /// not composed and must not be listed here — leaving them in made the overlap
    /// sweep report agent 0 colliding with the dial, which is the check correctly
    /// noticing that one cell cannot be two targets.
    public var hitTargets: [HitTarget] {
        var targets: [HitTarget] = []
        for (index, frame) in agentKeyFrames.enumerated() {
            targets.append(HitTarget(name: "agent \(index)", frame: frame, zone: .agents))
        }
        for slot in CommandSlot.allCases {
            targets.append(HitTarget(name: "command \(slot.rawValue)", frame: commandKeyFrame(slot), zone: .commands))
        }
        // The reference device puts status LEDs in this cell, which makes it the
        // honest home for the overflow indicator rather than a gap squeezed
        // between zones — and unlike that gap, it clears the hit floor.
        targets.append(HitTarget(name: "overflow", frame: statusClusterFrame, zone: .status))
        return targets
    }

    // MARK: - Type

    /// A base point size scaled for this layout, never below `minimumFontSize`.
    public func fontSize(_ base: CGFloat) -> CGFloat {
        max(PanelLayout.minimumFontSize, base * scale)
    }

    // MARK: - Self check

    /// Validates the invariants at every size class. Empty means healthy.
    public static func selfCheckFailures() -> [String] {
        let epsilon: CGFloat = 0.01
        var failures: [String] = []

        func s_bleed(_ layout: PanelLayout) -> CGFloat { glowBleed * layout.scale }

        func describe(_ rect: CGRect) -> String {
            String(format: "(%.1f,%.1f %.1fx%.1f)", rect.minX, rect.minY, rect.width, rect.height)
        }

        if minimumScale > 1 {
            failures.append("base geometry is below the \(minimumHitTarget)pt hit floor even at regular size")
        }

        for sizeClass in SizeClass.allCases {
            let layout = PanelLayout(sizeClass: sizeClass)
            let tag = sizeClass.rawValue
            let panel = layout.panelBounds.insetBy(dx: -epsilon, dy: -epsilon)

            // The plate must sit inside the shell, and every cell inside the plate.
            if !panel.contains(layout.caseFrame) {
                failures.append("\(tag): case \(describe(layout.caseFrame)) escapes panel")
            }
            if !layout.caseFrame.insetBy(dx: -epsilon, dy: -epsilon).contains(layout.plateFrame) {
                failures.append("\(tag): plate \(describe(layout.plateFrame)) escapes the case")
            }
            // The glow needs real room on every side or it clips.
            if layout.caseFrame.minX < s_bleed(layout) - epsilon {
                failures.append("\(tag): no glow bleed margin on the left")
            }
            let plate = layout.plateFrame.insetBy(dx: -epsilon, dy: -epsilon)
            for target in layout.hitTargets where !plate.contains(target.frame) {
                failures.append("\(tag): \(target.name) \(describe(target.frame)) escapes the plate")
            }

            // Deliberately NOT checking zone-vs-zone overlap: zones are logical
            // bounding boxes and the agent group encloses the encoder and stick.
            // The real invariant is that no two interactive targets collide.
            let sweepable = layout.hitTargets.filter { !$0.nested }
            for (index, first) in sweepable.enumerated() {
                for second in sweepable[(index + 1)...]
                where first.frame.insetBy(dx: epsilon, dy: epsilon)
                    .intersects(second.frame.insetBy(dx: epsilon, dy: epsilon)) {
                    failures.append("\(tag): \(first.name) overlaps \(second.name)")
                }
                if min(first.frame.width, first.frame.height) < minimumHitTarget - epsilon {
                    failures.append(
                        "\(tag): \(first.name) is \(describe(first.frame)), under the \(minimumHitTarget)pt hit floor"
                    )
                }
            }

            // Nested regions must actually sit inside a real target.
            for nested in layout.hitTargets where nested.nested {
                let enclosing = sweepable.first { $0.frame.insetBy(dx: -epsilon, dy: -epsilon).contains(nested.frame) }
                if enclosing == nil {
                    failures.append("\(tag): nested \(nested.name) is not inside any target")
                }
            }

            for base in [8, 9, 10, 14] as [CGFloat] where layout.fontSize(base) < minimumFontSize {
                failures.append("\(tag): base \(base)pt resolves to \(layout.fontSize(base))pt, under the floor")
            }

            if layout.agentKeyFrames.count != agentKeyCount {
                failures.append("\(tag): expected \(agentKeyCount) agent keys, got \(layout.agentKeyFrames.count)")
            }
            if layout.commandKeyFrames.count != CommandSlot.allCases.count {
                failures.append("\(tag): command key frames do not cover every CommandSlot")
            }
            // The device is square-ish; a wildly non-square panel means the grid
            // maths drifted from the reference.
            let ratio = layout.panelSize.width / layout.panelSize.height
            if ratio < 0.9 || ratio > 1.2 {
                failures.append("\(tag): panel aspect \(String(format: "%.2f", ratio)) is not close to square")
            }
        }

        return failures
    }
}
