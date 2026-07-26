import AppKit
import SwiftUI

/// The one place state colour lives. Every key, glow and label reads from here,
/// so a palette change touches this file and nothing else.
///
/// Not an asset catalog, deliberately: this machine has Command Line Tools only,
/// so there is no `actool` and `.xcassets` cannot be compiled by SwiftPM here.
/// Colours are therefore plain Swift values. That turns out to be the better
/// trade anyway — the numbers are readable in review and `selfCheckFailures()`
/// can measure real WCAG contrast on them, which an asset catalog cannot do
/// without a running app.
///
/// Names describe meaning, never hue. `runningGlow`, not `blue` — the mapping
/// from state to colour is allowed to change; the vocabulary is not.
///
/// Contrast is measured, not assumed. Keys are translucent over the panel
/// backdrop, so the label is checked against the *composed* fill (fill blended
/// onto the backdrop at its own opacity) rather than the raw fill, because the
/// composed colour is what the eye actually sees. In increased-contrast mode
/// translucency is dropped to opaque and the edge stroke thickens, per the
/// Reduce Transparency requirement.
public enum StateColors {

    // MARK: - Colour value

    /// An sRGB colour as extended-linear-free components in 0...1. Kept as raw
    /// numbers rather than `Color` so contrast can be computed without a
    /// rendering context.
    public struct RGB: Sendable, Equatable, Hashable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// `RGB(0x0A54C6)` — 8 bits per channel, sRGB.
        public init(_ hex: UInt32) {
            self.init(
                red: Double((hex >> 16) & 0xFF) / 255,
                green: Double((hex >> 8) & 0xFF) / 255,
                blue: Double(hex & 0xFF) / 255
            )
        }

        public var color: Color { Color(nsColor: nsColor) }

        public var nsColor: NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }

        /// This colour drawn at `alpha` over `backdrop`. Straight source-over in
        /// sRGB space, which is what Core Animation does for a solid layer.
        public func composited(over backdrop: RGB, alpha: Double) -> RGB {
            RGB(
                red: red * alpha + backdrop.red * (1 - alpha),
                green: green * alpha + backdrop.green * (1 - alpha),
                blue: blue * alpha + backdrop.blue * (1 - alpha)
            )
        }
    }

    // MARK: - Appearance

    /// The four combinations a key has to survive. Increased contrast is a
    /// separate axis from light/dark, not a modifier applied afterwards, because
    /// the fills genuinely differ rather than just getting darker.
    public enum Appearance: String, CaseIterable, Sendable {
        case light
        case dark
        case lightIncreasedContrast
        case darkIncreasedContrast

        public var isDark: Bool {
            self == .dark || self == .darkIncreasedContrast
        }

        public var isIncreasedContrast: Bool {
            self == .lightIncreasedContrast || self == .darkIncreasedContrast
        }

        fileprivate var appearanceName: NSAppearance.Name {
            switch self {
            case .light: .aqua
            case .dark: .darkAqua
            case .lightIncreasedContrast: .accessibilityHighContrastAqua
            case .darkIncreasedContrast: .accessibilityHighContrastDarkAqua
            }
        }
    }

    /// The panel surface a key sits on. Needed for the contrast maths, and it is
    /// the honest backdrop for the frosted material at rest.
    public static func panelBackdrop(_ appearance: Appearance) -> RGB {
        switch appearance {
        case .light: RGB(0xE8E8ED)
        case .dark: RGB(0x1C1C1E)
        case .lightIncreasedContrast: RGB(0xFFFFFF)
        case .darkIncreasedContrast: RGB(0x000000)
        }
    }

    // MARK: - Swatch

    /// Everything one key needs for one state in one appearance.
    ///
    /// `keyEdge` is the label colour by construction: the label is already proven
    /// to clear 4.5:1 against the fill, so reusing it means the border can never
    /// be the thing that disappears. One value, one guarantee.
    public struct StateSwatch: Sendable, Equatable {
        /// Tint of the key face, before opacity.
        public let keyFill: RGB
        /// Text and icon colour, legible on `composedKeyFill`.
        public let keyLabel: RGB
        /// Halo colour. Carries the state at a glance; never the only signal.
        public let stateGlow: RGB
        /// Border stroke colour.
        public let keyEdge: RGB
        /// 1.0 in increased contrast — translucency is dropped there.
        public let fillOpacity: Double
        public let glowOpacity: Double
        /// Blur radius in points. Smaller in increased contrast: a tight halo
        /// reads as a defined edge, a wide one reads as mush.
        public let glowRadius: Double
        public let edgeWidth: Double
        /// The panel surface this swatch was resolved against.
        public let backdrop: RGB

        /// What the eye sees where the label sits. Contrast is measured here.
        public var composedKeyFill: RGB {
            keyFill.composited(over: backdrop, alpha: fillOpacity)
        }
    }

    /// Per-state colour source of truth. Four fill/label pairs because increased
    /// contrast changes the fill, not just the text.
    private struct StatePalette {
        let lightFill: RGB, lightLabel: RGB
        let darkFill: RGB, darkLabel: RGB
        let lightContrastFill: RGB, lightContrastLabel: RGB
        let darkContrastFill: RGB, darkContrastLabel: RGB
        let lightGlow: RGB, darkGlow: RGB
        /// Base opacity of the frosted face outside increased-contrast mode.
        let restingFillOpacity: Double
        let restingGlowOpacity: Double
        let restingGlowRadius: Double
    }

    /// Switched rather than looked up in a dictionary on purpose: adding an
    /// eighth `AgentState` becomes a compile error here instead of a missing
    /// colour at runtime.
    private static func palette(for state: AgentState) -> StatePalette {
        switch state {
        // No session bound. Unlit, recessed, all but no halo — an empty slot
        // should look empty rather than look like a state.
        case .unassigned:
            StatePalette(
                lightFill: RGB(0xC6C6CE), lightLabel: RGB(0x2B2B31),
                darkFill: RGB(0x2E2E34), darkLabel: RGB(0xA9A9B4),
                lightContrastFill: RGB(0xD8D8DE), lightContrastLabel: RGB(0x000000),
                darkContrastFill: RGB(0x232329), darkContrastLabel: RGB(0xC8C8D0),
                lightGlow: RGB(0x8E8E9A), darkGlow: RGB(0x4A4A52),
                restingFillOpacity: 0.55, restingGlowOpacity: 0.10, restingGlowRadius: 2
            )

        // Bound and alive but doing nothing. White: present, not working.
        case .idle:
            StatePalette(
                lightFill: RGB(0xFDFDFF), lightLabel: RGB(0x1F1F24),
                darkFill: RGB(0xE9E9F0), darkLabel: RGB(0x141418),
                lightContrastFill: RGB(0xFFFFFF), lightContrastLabel: RGB(0x000000),
                darkContrastFill: RGB(0xFFFFFF), darkContrastLabel: RGB(0x000000),
                lightGlow: RGB(0xFFFFFF), darkGlow: RGB(0xFFFFFF),
                restingFillOpacity: 0.85, restingGlowOpacity: 0.55, restingGlowRadius: 9
            )

        // Working. The one state that animates, so it wants the widest halo.
        case .running:
            StatePalette(
                lightFill: RGB(0x0A54C6), lightLabel: RGB(0xFFFFFF),
                darkFill: RGB(0x1E64E0), darkLabel: RGB(0xFFFFFF),
                lightContrastFill: RGB(0x00429E), lightContrastLabel: RGB(0xFFFFFF),
                darkContrastFill: RGB(0x3D8BFF), darkContrastLabel: RGB(0x000000),
                lightGlow: RGB(0x2E7BFF), darkGlow: RGB(0x4A90FF),
                restingFillOpacity: 0.92, restingGlowOpacity: 0.75, restingGlowRadius: 12
            )

        // Finished cleanly.
        case .complete:
            StatePalette(
                lightFill: RGB(0x12693A), lightLabel: RGB(0xFFFFFF),
                darkFill: RGB(0x1E7D45), darkLabel: RGB(0xFFFFFF),
                lightContrastFill: RGB(0x004C24), lightContrastLabel: RGB(0xFFFFFF),
                darkContrastFill: RGB(0x3FD07A), darkContrastLabel: RGB(0x000000),
                lightGlow: RGB(0x25A55C), darkGlow: RGB(0x3ED27C),
                restingFillOpacity: 0.90, restingGlowOpacity: 0.70, restingGlowRadius: 10
            )

        // Blocked on the user. Attention-worthy, so it glows hardest of the
        // non-failures.
        case .needsInput:
            StatePalette(
                lightFill: RGB(0xF0A63C), lightLabel: RGB(0x241703),
                darkFill: RGB(0xE39A2E), darkLabel: RGB(0x201502),
                lightContrastFill: RGB(0xFFB43C), lightContrastLabel: RGB(0x000000),
                darkContrastFill: RGB(0xFFC24D), darkContrastLabel: RGB(0x000000),
                lightGlow: RGB(0xFFB44A), darkGlow: RGB(0xFFC15C),
                restingFillOpacity: 0.92, restingGlowOpacity: 0.85, restingGlowRadius: 13
            )

        // Failed.
        case .error:
            StatePalette(
                lightFill: RGB(0xC4172B), lightLabel: RGB(0xFFFFFF),
                darkFill: RGB(0xD4293C), darkLabel: RGB(0xFFFFFF),
                lightContrastFill: RGB(0x98000F), lightContrastLabel: RGB(0xFFFFFF),
                darkContrastFill: RGB(0xFF6A78), darkContrastLabel: RGB(0x000000),
                lightGlow: RGB(0xE83A4C), darkGlow: RGB(0xFF5566),
                restingFillOpacity: 0.92, restingGlowOpacity: 0.85, restingGlowRadius: 13
            )

        // Bound, but the state source went quiet. Deliberately *lit* neutral
        // grey: it must not read as an empty slot, because "we lost track of a
        // real session" and "nothing here" are different facts and confusing
        // them is the drift failure the PRD names as risk #1.
        case .unknown:
            StatePalette(
                lightFill: RGB(0x5D5D6B), lightLabel: RGB(0xFFFFFF),
                darkFill: RGB(0x6A6A7A), darkLabel: RGB(0xFFFFFF),
                lightContrastFill: RGB(0x4A4A56), lightContrastLabel: RGB(0xFFFFFF),
                darkContrastFill: RGB(0x9A9AA8), darkContrastLabel: RGB(0x000000),
                lightGlow: RGB(0x9A9AA8), darkGlow: RGB(0xB0B0BE),
                restingFillOpacity: 0.94, restingGlowOpacity: 0.60, restingGlowRadius: 8
            )
        }
    }

    /// The resolved palette for one state in one appearance.
    public static func swatch(for state: AgentState, in appearance: Appearance) -> StateSwatch {
        let p = palette(for: state)
        let hc = appearance.isIncreasedContrast

        let fill: RGB
        let label: RGB
        switch appearance {
        case .light: (fill, label) = (p.lightFill, p.lightLabel)
        case .dark: (fill, label) = (p.darkFill, p.darkLabel)
        case .lightIncreasedContrast: (fill, label) = (p.lightContrastFill, p.lightContrastLabel)
        case .darkIncreasedContrast: (fill, label) = (p.darkContrastFill, p.darkContrastLabel)
        }

        return StateSwatch(
            keyFill: fill,
            keyLabel: label,
            stateGlow: appearance.isDark ? p.darkGlow : p.lightGlow,
            keyEdge: label,
            // Increased contrast: opaque face, tighter halo, visible border.
            fillOpacity: hc ? 1.0 : p.restingFillOpacity,
            glowOpacity: hc ? min(1.0, p.restingGlowOpacity + 0.15) : p.restingGlowOpacity,
            glowRadius: hc ? p.restingGlowRadius * 0.6 : p.restingGlowRadius,
            edgeWidth: hc ? 1.5 : 0.5,
            backdrop: panelBackdrop(appearance)
        )
    }

    // MARK: - SwiftUI accessors

    /// Appearance-tracking key face tint. Resolves itself when the system theme
    /// or the Increase Contrast setting changes, so views need no observers.
    public static func keyFill(_ state: AgentState) -> Color {
        dynamic("keyFill.\(state.rawValue)") { swatch(for: state, in: $0).keyFill }
    }

    /// Label and icon colour, measured legible on the composed key face.
    public static func keyLabel(_ state: AgentState) -> Color {
        dynamic("keyLabel.\(state.rawValue)") { swatch(for: state, in: $0).keyLabel }
    }

    public static func stateGlow(_ state: AgentState) -> Color {
        dynamic("stateGlow.\(state.rawValue)") { swatch(for: state, in: $0).stateGlow }
    }

    public static func keyEdge(_ state: AgentState) -> Color {
        dynamic("keyEdge.\(state.rawValue)") { swatch(for: state, in: $0).keyEdge }
    }

    /// The swatch for the appearance currently drawing, including the system
    /// Increase Contrast setting. For opacity, radius and stroke width — the
    /// numbers a dynamic `Color` cannot carry.
    @MainActor
    public static func resolvedSwatch(for state: AgentState) -> StateSwatch {
        swatch(for: state, in: currentAppearance())
    }

    @MainActor
    public static func currentAppearance() -> Appearance {
        let increased = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        switch (dark, increased) {
        case (false, false): return .light
        case (true, false): return .dark
        case (false, true): return .lightIncreasedContrast
        case (true, true): return .darkIncreasedContrast
        }
    }

    private static let appearanceNames: [NSAppearance.Name] =
        Appearance.allCases.map(\.appearanceName)

    private static func dynamic(
        _ name: String,
        _ pick: @escaping (Appearance) -> RGB
    ) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            let matched = appearance.bestMatch(from: appearanceNames) ?? .aqua
            let resolved = Appearance.allCases.first { $0.appearanceName == matched } ?? .light
            return pick(resolved).nsColor
        })
    }

    // MARK: - Contrast

    /// WCAG 2.1 relative luminance. Real formula, sRGB gamma expansion included —
    /// the whole point of this file is that the ratios are measured.
    public static func relativeLuminance(_ c: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue)
    }

    /// WCAG 2.1 contrast ratio, 1.0...21.0.
    public static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = relativeLuminance(a)
        let lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// WCAG 2.1 AA for normal-size text. Labels are small on a compact panel, so
    /// the large-text 3:1 allowance does not apply.
    public static let minimumLabelContrast = 4.5

    /// Floor for telling `unknown` apart from `unassigned` by fill alone. Not a
    /// WCAG number — a legibility one. Below this the two read as the same tile.
    public static let minimumStateSeparation = 1.8

    // MARK: - Self check

    /// Measured, not asserted. Empty when the palette is healthy.
    /// Wired into `SelfCheck.run()`.
    public static func selfCheckFailures() -> [String] {
        var failures: [String] = []

        func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

        for appearance in Appearance.allCases {
            // Label must be legible on the fill it actually sits on.
            for state in AgentState.allCases {
                let s = swatch(for: state, in: appearance)
                let ratio = contrastRatio(s.keyLabel, s.composedKeyFill)
                if ratio < minimumLabelContrast {
                    failures.append(
                        "\(state.rawValue) label contrast \(fmt(ratio)):1 in \(appearance.rawValue), needs \(fmt(minimumLabelContrast)):1"
                    )
                }
            }

            // allCases, so an eighth state cannot be silently missed.
            var byFill: [RGB: [AgentState]] = [:]
            for state in AgentState.allCases {
                byFill[swatch(for: state, in: appearance).composedKeyFill, default: []].append(state)
            }
            for (_, states) in byFill where states.count > 1 {
                let names = states.map(\.rawValue).sorted().joined(separator: ", ")
                failures.append("states share one fill in \(appearance.rawValue): \(names)")
            }

            // "No session" and "lost track of a session" must not look alike.
            let unknown = swatch(for: .unknown, in: appearance)
            let unassigned = swatch(for: .unassigned, in: appearance)
            let separation = contrastRatio(unknown.composedKeyFill, unassigned.composedKeyFill)
            if separation < minimumStateSeparation {
                failures.append(
                    "unknown vs unassigned separation \(fmt(separation)):1 in \(appearance.rawValue), needs \(fmt(minimumStateSeparation)):1"
                )
            }
            if unknown.stateGlow == unassigned.stateGlow {
                failures.append("unknown and unassigned share a glow in \(appearance.rawValue)")
            }

            // Increased contrast means no translucency and a real border.
            if appearance.isIncreasedContrast {
                for state in AgentState.allCases {
                    let s = swatch(for: state, in: appearance)
                    if s.fillOpacity < 1 {
                        failures.append("\(state.rawValue) still translucent in \(appearance.rawValue)")
                    }
                    if s.edgeWidth < 1 {
                        failures.append("\(state.rawValue) edge too thin in \(appearance.rawValue)")
                    }
                }
            }
        }

        return failures
    }

    /// Every measured ratio, for the record. Not used by the check — read it when
    /// changing a colour to see what the change cost.
    public static func contrastReport() -> String {
        var lines: [String] = []
        for state in AgentState.allCases {
            let cells = Appearance.allCases.map { appearance -> String in
                let s = swatch(for: state, in: appearance)
                let ratio = contrastRatio(s.keyLabel, s.composedKeyFill)
                return String(format: "%@=%.2f", appearance.rawValue, ratio)
            }
            lines.append(state.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
                + cells.joined(separator: "  "))
        }
        return lines.joined(separator: "\n")
    }
}
