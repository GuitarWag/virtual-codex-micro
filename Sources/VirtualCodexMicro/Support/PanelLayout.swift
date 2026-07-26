import CoreGraphics
import Foundation

/// Single source of truth for the panel's geometry. Every view reads its
/// position and size from here, so a spacing change is one edit rather than six.
///
/// Coordinate space is SwiftUI's: origin top-left, y grows downward. Frames are
/// absolute within `panelBounds`, so a view places itself with
/// `.position(x: frame.midX, y: frame.midY)` inside a `ZStack` sized to
/// `panelSize`, or with `.offset` under `.topLeading` alignment.
///
/// Fidelity note: zone order, zone placement and key counts follow the hardware
/// control map — six agent keys in a 3x2 block as the dominant cluster, command
/// keys as a quieter secondary cluster, dial on the right, four-way pad
/// lower-left. Absolute proportions do not. The hardware's keycaps are sized for
/// fingers on a pitch we have no reason to copy; a pointer needs a reliable
/// click target and a screen has no travel or tactile edge to help it land. So
/// the numbers below are tuned for `minimumHitTarget`, and the deliberate
/// deviation is that the four-way pad is proportionally larger than a physical
/// thumb joystick would be — five targets in one 3x3 grid is the tightest zone
/// on the panel, and it, not the agent keys, sets the floor for how small the
/// compact size can go.
public struct PanelLayout: Sendable, Equatable {

    // MARK: - Size classes

    public enum SizeClass: String, CaseIterable, Sendable {
        case compact
        case regular

        /// One factor drives everything. Overlap and containment are
        /// scale-invariant, so adding a size class later cannot break the layout
        /// — only the hit-target floor is scale-dependent, and it is clamped.
        public var scale: CGFloat {
            switch self {
            case .compact: max(PanelLayout.requestedCompactScale, PanelLayout.minimumScale)
            case .regular: 1
            }
        }
    }

    public enum Zone: String, CaseIterable, Sendable {
        case agents
        case commands
        case dial
        case pad
    }

    /// Fixed-purpose command keys in stable grid order (row-major). Positions
    /// are load-bearing for muscle memory: accept sits top-left because it is
    /// the most used, and this ordering must not be reshuffled once shipped.
    public enum CommandSlot: String, CaseIterable, Sendable {
        case accept
        case reject
        case newSession
        case pushToTalk
        case custom1
        case custom2
    }

    public enum PadDirection: String, CaseIterable, Sendable {
        case up
        case right
        case down
        case left
        case center
    }

    // MARK: - Hit target floor

    /// No interactive element is ever smaller than this square, at any size
    /// class. A key too small to click reliably defeats the point of the panel.
    public static let minimumHitTarget: CGFloat = 28

    /// Smallest interactive element at base scale (one pad cell). The compact
    /// scale is clamped against this rather than trusted, so nudging
    /// `requestedCompactScale` down can shrink the panel but can never produce a
    /// key below the floor.
    static let smallestBaseTarget: CGFloat = padCellSide
    static let minimumScale: CGFloat = minimumHitTarget / smallestBaseTarget
    static let requestedCompactScale: CGFloat = 0.8

    // MARK: - Base geometry (regular size, points)

    private static let panelPadding: CGFloat = 16
    /// Gap between zones. Larger than the gap between keys inside a zone, so the
    /// four clusters read as four groups without needing borders.
    private static let zoneGap: CGFloat = 14

    private static let agentColumns = 3
    private static let agentRows = 2
    private static let agentKeySide: CGFloat = 56
    private static let agentKeyGap: CGFloat = 10

    private static let commandColumns = 3
    private static let commandRows = 2
    private static let commandKeySide: CGFloat = 40
    private static let commandKeyGap: CGFloat = 8

    /// 3x3 cell grid; the five cardinal cells are targets, corners are inert.
    private static let padCellSide: CGFloat = 36
    private static let padSide: CGFloat = padCellSide * 3

    private static let dialDiameter: CGFloat = 108
    /// Centre reset target, concentric inside the ring.
    private static let dialCenterDiameter: CGFloat = 40

    private static let baseCornerRadius: CGFloat = 22
    private static let baseAgentKeyCornerRadius: CGFloat = 12
    private static let baseCommandKeyCornerRadius: CGFloat = 9

    // Derived base rects. Written once here; everything public just scales them.
    private static let agentZoneBase = CGRect(
        x: panelPadding,
        y: panelPadding,
        width: CGFloat(agentColumns) * agentKeySide + CGFloat(agentColumns - 1) * agentKeyGap,
        height: CGFloat(agentRows) * agentKeySide + CGFloat(agentRows - 1) * agentKeyGap
    )

    private static let padZoneBase = CGRect(
        x: panelPadding,
        y: agentZoneBase.maxY + zoneGap,
        width: padSide,
        height: padSide
    )

    private static let commandZoneBase: CGRect = {
        let width = CGFloat(commandColumns) * commandKeySide + CGFloat(commandColumns - 1) * commandKeyGap
        let height = CGFloat(commandRows) * commandKeySide + CGFloat(commandRows - 1) * commandKeyGap
        return CGRect(
            x: padZoneBase.maxX + zoneGap,
            y: padZoneBase.midY - height / 2,
            width: width,
            height: height
        )
    }()

    private static let panelSizeBase = CGSize(
        width: max(agentZoneBase.maxX, commandZoneBase.maxX) + zoneGap + dialDiameter + panelPadding,
        height: padZoneBase.maxY + panelPadding
    )

    /// Right-side band, vertically centred on the panel rather than aligned to a
    /// neighbouring zone — a rotary reads as its own control, not as part of a
    /// row.
    private static let dialZoneBase = CGRect(
        x: panelSizeBase.width - panelPadding - dialDiameter,
        y: (panelSizeBase.height - dialDiameter) / 2,
        width: dialDiameter,
        height: dialDiameter
    )

    // MARK: - Instance

    public let sizeClass: SizeClass

    public init(sizeClass: SizeClass) {
        self.sizeClass = sizeClass
    }

    public static let compact = PanelLayout(sizeClass: .compact)
    public static let regular = PanelLayout(sizeClass: .regular)

    public var scale: CGFloat { sizeClass.scale }

    private func scaled(_ value: CGFloat) -> CGFloat { value * scale }

    private func scaled(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    // MARK: - Panel

    public var panelSize: CGSize {
        CGSize(width: scaled(Self.panelSizeBase.width), height: scaled(Self.panelSizeBase.height))
    }

    public var panelBounds: CGRect { CGRect(origin: .zero, size: panelSize) }

    /// Corner radius of the device-like silhouette that replaces window chrome.
    public var cornerRadius: CGFloat { scaled(Self.baseCornerRadius) }

    public var agentKeyCornerRadius: CGFloat { scaled(Self.baseAgentKeyCornerRadius) }
    public var commandKeyCornerRadius: CGFloat { scaled(Self.baseCommandKeyCornerRadius) }

    // MARK: - Zones

    public var agentZone: CGRect { scaled(Self.agentZoneBase) }
    public var commandZone: CGRect { scaled(Self.commandZoneBase) }
    public var dialZone: CGRect { scaled(Self.dialZoneBase) }
    public var padZone: CGRect { scaled(Self.padZoneBase) }

    public func zoneFrame(_ zone: Zone) -> CGRect {
        switch zone {
        case .agents: agentZone
        case .commands: commandZone
        case .dial: dialZone
        case .pad: padZone
        }
    }

    public var zoneFrames: [(zone: Zone, frame: CGRect)] {
        Zone.allCases.map { ($0, zoneFrame($0)) }
    }

    // MARK: - Agent keys (zone 1)

    public static let agentKeyCount = agentColumns * agentRows

    /// Row-major: index 0 is top-left, 2 is top-right, 3 starts the second row.
    /// Slot identity is stable, so key 3 stays key 3 across size classes.
    public var agentKeyFrames: [CGRect] {
        (0 ..< Self.agentKeyCount).map { index in
            let column = index % Self.agentColumns
            let row = index / Self.agentColumns
            return scaled(
                CGRect(
                    x: Self.agentZoneBase.minX + CGFloat(column) * (Self.agentKeySide + Self.agentKeyGap),
                    y: Self.agentZoneBase.minY + CGFloat(row) * (Self.agentKeySide + Self.agentKeyGap),
                    width: Self.agentKeySide,
                    height: Self.agentKeySide
                )
            )
        }
    }

    /// Traps on an out-of-range index: `agentKeyCount` is fixed, so a bad index
    /// is a programming error, and a silently-zero frame would draw a key at the
    /// panel origin instead of failing.
    public func agentKeyFrame(_ index: Int) -> CGRect { agentKeyFrames[index] }

    // MARK: - Command keys (zone 2)

    public var commandKeyFrames: [CGRect] {
        CommandSlot.allCases.indices.map { index in
            let column = index % Self.commandColumns
            let row = index / Self.commandColumns
            return scaled(
                CGRect(
                    x: Self.commandZoneBase.minX + CGFloat(column) * (Self.commandKeySide + Self.commandKeyGap),
                    y: Self.commandZoneBase.minY + CGFloat(row) * (Self.commandKeySide + Self.commandKeyGap),
                    width: Self.commandKeySide,
                    height: Self.commandKeySide
                )
            )
        }
    }

    public func commandKeyFrame(_ slot: CommandSlot) -> CGRect {
        commandKeyFrames[CommandSlot.allCases.firstIndex(of: slot) ?? 0]
    }

    // MARK: - Dial (zone 3)

    public var dialFrame: CGRect { dialZone }

    /// Concentric inside `dialFrame` by design — the reset target is part of the
    /// rotary, not a sibling key, so it is exempt from the overlap sweep.
    public var dialCenterFrame: CGRect {
        let outer = Self.dialZoneBase
        let inset = (Self.dialDiameter - Self.dialCenterDiameter) / 2
        return scaled(outer.insetBy(dx: inset, dy: inset))
    }

    // MARK: - Four-direction pad (zone 4)

    public func padFrame(_ direction: PadDirection) -> CGRect {
        let (column, row): (Int, Int) = switch direction {
        case .up: (1, 0)
        case .left: (0, 1)
        case .center: (1, 1)
        case .right: (2, 1)
        case .down: (1, 2)
        }
        return scaled(
            CGRect(
                x: Self.padZoneBase.minX + CGFloat(column) * Self.padCellSide,
                y: Self.padZoneBase.minY + CGFloat(row) * Self.padCellSide,
                width: Self.padCellSide,
                height: Self.padCellSide
            )
        )
    }

    /// The four diagonal cells of the 3x3 grid are inert, so a slip between up
    /// and right fires nothing rather than the wrong preset.
    public var padTargetFrames: [(direction: PadDirection, frame: CGRect)] {
        PadDirection.allCases.map { ($0, padFrame($0)) }
    }

    // MARK: - Hit targets

    public struct HitTarget: Sendable, Equatable {
        public let name: String
        public let frame: CGRect
        public let zone: Zone
        /// Sits inside another target by construction; skipped by the overlap check.
        public let nested: Bool
    }

    /// Every pointer-hittable element, in zone order. Doubles as a sane default
    /// keyboard traversal order: agent keys, command keys, pad, dial.
    public var hitTargets: [HitTarget] {
        var targets: [HitTarget] = []
        for (index, frame) in agentKeyFrames.enumerated() {
            targets.append(HitTarget(name: "agent \(index)", frame: frame, zone: .agents, nested: false))
        }
        for (slot, frame) in zip(CommandSlot.allCases, commandKeyFrames) {
            targets.append(HitTarget(name: "command \(slot.rawValue)", frame: frame, zone: .commands, nested: false))
        }
        for (direction, frame) in padTargetFrames {
            targets.append(HitTarget(name: "pad \(direction.rawValue)", frame: frame, zone: .pad, nested: false))
        }
        targets.append(HitTarget(name: "dial ring", frame: dialFrame, zone: .dial, nested: false))
        targets.append(HitTarget(name: "dial reset", frame: dialCenterFrame, zone: .dial, nested: true))
        return targets
    }

    // MARK: - Invariants

    /// Validates the layout invariants at every size class. Empty means healthy.
    /// Wired into `SelfCheck`; this is the proof the numbers above hold together
    /// after anyone edits them.
    public static func selfCheckFailures() -> [String] {
        // Slack for the float error introduced by scaling; gaps are >= 6pt at
        // the compact scale, so this can never mask a real collision.
        let epsilon: CGFloat = 0.01
        var failures: [String] = []

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
            let zones = layout.zoneFrames

            for (zone, frame) in zones where !panel.contains(frame) {
                failures.append(
                    "\(tag): zone \(zone.rawValue) \(describe(frame)) escapes panel \(describe(layout.panelBounds))"
                )
            }

            for (index, first) in zones.enumerated() {
                for second in zones[(index + 1)...]
                where first.frame.insetBy(dx: epsilon, dy: epsilon)
                    .intersects(second.frame.insetBy(dx: epsilon, dy: epsilon)) {
                    failures.append("\(tag): zones \(first.zone.rawValue) and \(second.zone.rawValue) overlap")
                }
            }

            let targets = layout.hitTargets

            for target in targets {
                let zone = layout.zoneFrame(target.zone).insetBy(dx: -epsilon, dy: -epsilon)
                if !zone.contains(target.frame) {
                    failures.append(
                        "\(tag): \(target.name) \(describe(target.frame)) escapes zone \(target.zone.rawValue)"
                    )
                }
                if min(target.frame.width, target.frame.height) < minimumHitTarget - epsilon {
                    failures.append(
                        "\(tag): \(target.name) is \(describe(target.frame)), under the \(minimumHitTarget)pt hit floor"
                    )
                }
            }

            let sweepable = targets.filter { !$0.nested }
            for (index, first) in sweepable.enumerated() {
                for second in sweepable[(index + 1)...]
                where first.frame.insetBy(dx: epsilon, dy: epsilon)
                    .intersects(second.frame.insetBy(dx: epsilon, dy: epsilon)) {
                    failures.append("\(tag): \(first.name) overlaps \(second.name)")
                }
            }

            if layout.agentKeyFrames.count != agentKeyCount {
                failures.append("\(tag): expected \(agentKeyCount) agent keys, got \(layout.agentKeyFrames.count)")
            }
            if layout.commandKeyFrames.count != CommandSlot.allCases.count {
                failures.append("\(tag): command key frames do not cover every CommandSlot")
            }
        }

        return failures
    }
}
