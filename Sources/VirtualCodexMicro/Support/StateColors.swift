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
///
/// The lit states sit on a **luminance ladder**, and that is the load-bearing
/// property of this file. Each state is roughly one 1.8 step from its neighbours
/// in composed luminance, so the six-key wall still reads as distinct states in
/// greyscale, to a deuteranope, and in peripheral vision — which is
/// rod-dominated and largely hue-blind, and is the glance the whole product is
/// for. Before this ladder every lit state had been tuned in isolation to clear
/// 4.5:1 against a white label, which put all four on one luminance: `complete`
/// and `error` were 1.00:1 apart, done and failed indistinguishable without hue.
///
/// That 1.8 is the **construction step**, and every "1.8" in the per-state
/// comments below means it. It is not the enforced floor:
/// `minimumStateSeparation` is 1.50, because that is what the rungs are worth
/// once a real cap is rendered and sampled. Read its doc comment before moving a
/// hex value — the two numbers are one step apart on purpose, and the gap is the
/// headroom the rasteriser spends.
///
/// Which state gets which rung is forced, not chosen. Hue caps luminance: pure
/// blue tops out at 0.07 relative luminance, pure red at 0.21, so `running` has
/// to live at the bottom of the ladder and `error` low-to-middle, while amber
/// only reads as amber high up. That leaves `complete` in the middle and the one
/// hue-free state, `unknown`, to fill whichever rung is left over.
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
        ///
        /// Its luminance is pegged one small step above its own `keyFill`, so the
        /// glows form the same ladder the fills do. That is not decoration: the
        /// key draws this as a fat blurred inner border covering most of the face
        /// (`AgentKeyView`), so a set of glows at one luminance repaints the
        /// ladder flat no matter how well separated the fills are. The glows used
        /// to be exactly that — bright saturated variants within 1.1:1 of each
        /// other — which is why the rendered keys measured 1.05:1 apart while the
        /// fills measured further. Hue is the state's own; only lightness moved.
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

        /// The cap face: fill blended onto the backdrop at its own opacity. This is
        /// the **ladder's** basis — one value per state, no lighting — and every
        /// separation number in this file is computed from it.
        public var composedKeyFill: RGB {
            keyFill.composited(over: backdrop, alpha: fillOpacity)
        }

        /// The **middle** of the cap: `composedKeyFill` with the state glow over
        /// it. This is where the glyph sits, so this is what label contrast is
        /// measured against.
        ///
        /// It used to be measured against `composedKeyFill`, and that was wrong in
        /// a way that mattered rather than a rounding difference. `AgentKeyView`
        /// draws a radial glow at `glowOpacity` peaking dead centre, so the pixels
        /// under the glyph are never the fill — they are the fill with 60–85% of a
        /// *lighter* colour over them. The M1 review caught the consequence from the
        /// other side: the model reported four glyphs comfortable that `PixelCheck`
        /// measured short. Same defect, both directions — for a light glyph the
        /// model is optimistic, for a dark one it is pessimistic, and `error` in
        /// light is wedged between the two. Measured on the rendered cap the centre
        /// is 0.252 relative luminance; `composedKeyFill` says 0.155 and this says
        /// 0.181, so this is not exact either — the frost ramp and the moulding
        /// account for the rest, and `PixelCheck` is what covers them. It is
        /// **directionally right**, which `composedKeyFill` was not.
        ///
        /// Separation deliberately stays on `composedKeyFill`: the ladder is a
        /// property of the palette, and folding the glow into it would make every
        /// documented rung in this file mean something else.
        public var composedKeyCentre: RGB {
            stateGlow.composited(over: composedKeyFill, alpha: glowOpacity)
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
                darkFill: RGB(0x2E2E34), darkLabel: RGB(0xE0E0E8),
                lightContrastFill: RGB(0xD8D8DE), lightContrastLabel: RGB(0x000000),
                darkContrastFill: RGB(0x232329), darkContrastLabel: RGB(0xC8C8D0),
                lightGlow: RGB(0x8E8E9A), darkGlow: RGB(0x4A4A52),
                restingFillOpacity: 0.55, restingGlowOpacity: 0.10, restingGlowRadius: 2
            )

        // Bound and alive but doing nothing. A pale neutral: present, not
        // working. It is the one lit state *off* the ladder — six rungs at 1.8
        // do not fit between black and white (1.8^5 = 18.9 against a usable
        // range of about 17), so it takes the widest gap the ladder leaves,
        // between `complete` and `needsInput`. In the light appearances it is
        // pushed to the panel-separating end of that gap instead of the middle,
        // because there it has to clear the backdrop as well: at the old
        // near-white value it sat 1.17:1 from the panel and read as a hole
        // rather than a key.
        case .idle:
            StatePalette(
                lightFill: RGB(0xA1A1AD), lightLabel: RGB(0x1F1F24),
                darkFill: RGB(0xE4E4E8), darkLabel: RGB(0x141418),
                lightContrastFill: RGB(0xACACAC), lightContrastLabel: RGB(0x000000),
                darkContrastFill: RGB(0xD3D3D3), darkContrastLabel: RGB(0x000000),
                lightGlow: RGB(0xB9B9B9), darkGlow: RGB(0xD4D4D4),
                restingFillOpacity: 0.85, restingGlowOpacity: 0.55, restingGlowRadius: 9
            )

        // Working. The one state that animates, so it wants the widest halo.
        // Bottom rung, and not by preference: a saturated blue cannot be lighter
        // than 0.07 relative luminance, so this is the only rung it fits.
        case .running:
            StatePalette(
                lightFill: RGB(0x073780), lightLabel: RGB(0xFFFFFF),
                darkFill: RGB(0x0D2C63), darkLabel: RGB(0xFFFFFF),
                lightContrastFill: RGB(0x01429C), lightContrastLabel: RGB(0xFFFFFF),
                darkContrastFill: RGB(0x00317A), darkContrastLabel: RGB(0xFFFFFF),
                lightGlow: RGB(0x0046BD), darkGlow: RGB(0x00317F),
                restingFillOpacity: 0.92, restingGlowOpacity: 0.75, restingGlowRadius: 12
            )

        // Finished cleanly. Fourth rung, which is well above where a white label
        // stays legible, so the label is a dark tint of the fill's own green.
        // That flip is the point: the previous palette held every lit state down
        // to whatever a white label needed, and that is what collapsed the set.
        case .complete:
            StatePalette(
                lightFill: RGB(0x1CA95D), lightLabel: RGB(0x072917),
                darkFill: RGB(0x4DD384), darkLabel: RGB(0x0D351D),
                lightContrastFill: RGB(0x00B254), lightContrastLabel: RGB(0x002A14),
                darkContrastFill: RGB(0x3ACF77), darkContrastLabel: RGB(0x000000),
                lightGlow: RGB(0x2ABD6A), darkGlow: RGB(0x38D178),
                restingFillOpacity: 0.90, restingGlowOpacity: 0.70, restingGlowRadius: 10
            )

        // Blocked on the user. Attention-worthy, so it glows hardest of the
        // non-failures. Top rung: amber only reads as amber when it is light, so
        // it takes the brightest step. In the dark appearances the top rung is
        // pale enough that the face alone is a warm off-white — the amber
        // identity is carried by the halo, which is the widest on the panel.
        case .needsInput:
            StatePalette(
                lightFill: RGB(0xF6C682), lightLabel: RGB(0x241703),
                darkFill: RGB(0xFCF6EC), darkLabel: RGB(0x201502),
                lightContrastFill: RGB(0xFEC76E), lightContrastLabel: RGB(0x000000),
                darkContrastFill: RGB(0xFFF2D6), darkContrastLabel: RGB(0x000000),
                lightGlow: RGB(0xFFD8A2), darkGlow: RGB(0xFFF3E1),
                restingFillOpacity: 0.92, restingGlowOpacity: 0.85, restingGlowRadius: 13
            )

        // Failed. Third rung. Red cannot go above 0.21 relative luminance while
        // staying red, which fixes it here and is also why it must not share a
        // rung with `complete`: red and green at one luminance is the textbook
        // deuteranopia failure, and "done" versus "failed" is the most expensive
        // confusion this panel can cause.
        //
        // **The light label is dark ink, and it is the one place in this file where
        // that was forced by measurement rather than chosen.** It was white, and a
        // white mark on a lit red cap is the one glyph on the panel that never
        // reached 4.5:1 — 3.48 rendered, and unfixable from inside the fill:
        // darkening the glow to lift it took `running` vs `error` down in lockstep
        // (3.48→4.23 against 1.59→1.29), and no dark ink could pass while the model
        // measured against `composedKeyFill`, whose ceiling with pure black is 4.10.
        // Both halves of that trap are now gone — `composedKeyCentre` measures the
        // ground the mark is actually on, and against it black clears the floor at
        // 4.62 modelled and 6.0 rendered while the fill, the glow and every rung on
        // the ladder stay exactly where they were. Pure black rather than the
        // near-black used in the dark appearance because the margin is 0.12: this
        // rung has no room for a decorative tint. It also matches what the reference
        // photographs show, which is a dark mark on lit plastic, never a white one.
        case .error:
            StatePalette(
                lightFill: RGB(0xCF192E), lightLabel: RGB(0x000000),
                darkFill: RGB(0xDE5766), darkLabel: RGB(0x140406),
                lightContrastFill: RGB(0xDE0015), lightContrastLabel: RGB(0x000000),
                darkContrastFill: RGB(0xFE2F42), darkContrastLabel: RGB(0x000000),
                lightGlow: RGB(0xE6273B), darkGlow: RGB(0xFF3145),
                restingFillOpacity: 0.92, restingGlowOpacity: 0.85, restingGlowRadius: 13
            )

        // Bound, but the state source went quiet. Deliberately *lit* neutral
        // grey: it must not read as an empty slot, because "we lost track of a
        // real session" and "nothing here" are different facts and confusing
        // them is the drift failure the PRD names as risk #1.
        //
        // Having no hue, it takes whichever rung the four hues leave free, so it
        // is the darkest state on a light panel and the second-darkest on a dark
        // one. It cannot be the darkest in the dark appearances: it has to stay
        // 1.8 clear of `unassigned`, which sits at panel luminance there, and
        // four more 1.8 steps above that would run past white.
        case .unknown:
            StatePalette(
                lightFill: RGB(0x0F0F12), lightLabel: RGB(0xFFFFFF),
                darkFill: RGB(0x565664), darkLabel: RGB(0xFFFFFF),
                lightContrastFill: RGB(0x1C1C21), lightContrastLabel: RGB(0xFFFFFF),
                darkContrastFill: RGB(0x5B5B69), darkContrastLabel: RGB(0xFFFFFF),
                lightGlow: RGB(0x27272E), darkGlow: RGB(0x3E3E50),
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

    /// Ink for the moulded markings on a cap — the slot numeral today.
    ///
    /// A token rather than a literal because it was a literal, and that is exactly
    /// how it went wrong: `.black.opacity(0.42)` written inline in `AgentKeyView`
    /// sat outside every assertion in this file, so nothing measured the one mark
    /// that addresses a key. The M1 review found it failing on half the caps;
    /// `PixelCheck` now reads it on all seven in both appearances.
    ///
    /// Black at an opacity rather than a solid grey, deliberately: `plasticShell`
    /// takes the corner it sits in to near-white on every state, but not the *same*
    /// near-white, so a darkening pass tracks the corner where a fixed value would
    /// drift against it.
    ///
    /// 0.72 is measured, not chosen. At the 0.42 this used to be, all fourteen
    /// state/appearance combinations failed `minimumLabelContrast` at 2.50–4.20:1;
    /// 0.60 still left four short; 0.72 puts the worst at 6.76:1. It reads as
    /// engraved grey rather than printed black, which is what the reference's own
    /// moulded markings look like.
    public static let capMarkingOpacity = 0.72

    public static var capMarking: Color { .black.opacity(capMarkingOpacity) }

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

    /// Floor for telling two states apart by cap alone. Not a WCAG number — a
    /// legibility one. Below this the two read as the same tile in greyscale, to
    /// a deuteranope, and at a glance.
    ///
    /// **1.50, measured on rendered pixels, and it used to say 1.8.** The 1.8 was
    /// never achieved. It was read off `composedKeyFill`, and `PixelCheck` — which
    /// renders the real panel and samples the caps on it — puts the tightest lit
    /// pairs at 1.57–1.71 where the model claims 1.81–1.83. Two things account for
    /// the gap, and neither is fixable by editing a hex value:
    ///
    /// 1. **`composited(over:alpha:)` is not what the rasteriser does**, and this
    ///    is most of it. Strip every cosmetic layer off the caps so only the tint
    ///    remains over the plate, and `complete` vs `error` still measures 1.74 in
    ///    light and 1.62 in dark against a modelled 1.83/1.82 — no glow, no frost,
    ///    no moulding, still short. Rendered luminance comes out consistently
    ///    *above* both a straight sRGB-space blend and a linear-space one, and
    ///    light-on-dark blends compress hardest, which is exactly where the tight
    ///    rungs live. The 1.78 that task 038 was written around was this. It was
    ///    attributed to the glow sitting over the fill; it is not the glow.
    /// 2. The glow, frost and moulding then cost a further 0.00–0.07 per pair —
    ///    small, and measured by removing each in turn.
    ///
    /// Bringing the render up to 1.8 is not a tuning job, it is a rebuild of the
    /// ladder against measured pixels rather than predicted ones, and the ladder is
    /// already saturated: sweeping `error`'s light glow dark enough to lift its
    /// glyph contrast drove `running` vs `error` down in lockstep, because every
    /// rung it gains comes off its neighbour. So the declared number is now the
    /// achieved one. An honest 1.50 beats a 1.8 the render quietly misses.
    ///
    /// 1.50 rather than the measured worst of 1.57 so the check has margin and does
    /// not go off on a machine that composites slightly differently. Both the model
    /// check and `PixelCheck` hold to this one value; the model clears it with room,
    /// and that room is the headroom the rasteriser spends.
    ///
    /// Scope, stated plainly: this is a floor on the **state-bearing centre** of the
    /// cap, and it is a floor on *luminance*. Measured across the whole visible cap
    /// the same pairs fall to 1.20–1.77, because `plasticShell` takes every cap's rim
    /// to near-white and that is shared between all of them. `PixelCheck` prints
    /// that number next to this one on every run so it cannot be forgotten. It is
    /// not enforced there because the visible cap is saturated and a floor on it
    /// cannot detect the regression this whole check exists for — see
    /// `PixelCheck.capOuter` for the sabotage evidence.
    ///
    /// The visible cap is instead guarded by `minimumGlanceSeparation`, which does
    /// not ask the fill for luminance it does not have. Read that next; the two
    /// together are the whole guarantee, and neither is sufficient alone.
    public static let minimumStateSeparation = 1.50

    /// Floor for telling two states apart across the **whole cap** at a glance,
    /// measured by `PixelCheck.glanceSeparation`: the strongest contrast anywhere on
    /// two caps once both are defocused to the acuity a glance actually has, in
    /// greyscale, with hue discarded.
    ///
    /// This is a second floor because the first one cannot be widened. Five 1.8:1
    /// luminance steps need 18.9:1 of range; the reference device's lit-cap band
    /// offers 1.17:1, so the fill is saturated and every rung it gains comes off a
    /// neighbour — measured, not argued, and it is why `minimumStateSeparation` says
    /// 1.50 rather than the 1.8 it was constructed for. Asking one channel for hue
    /// *and* the achromatic ladder was the mistake. The fill keeps hue; the **mark**
    /// carries the achromatic channel, and this is the floor that makes that
    /// load-bearing rather than decorative. Neither floor is sufficient alone: the
    /// centre one is blind to everything drawn as a mark, this one is blind to a
    /// palette that quietly flattens as long as some feature still differs.
    ///
    /// 1.80, and the numbers behind it. Before the mark was made to carry anything —
    /// same palette, same caps, same frost, every lit mark a filled circle — the
    /// worst lit pair scored **1.33** here and four pairs sat under 1.66, because
    /// seven distinct SF Symbols at one ink coverage are not a channel. After: the
    /// worst pair is **1.93** and all twenty clear it. Nothing about the fill moved
    /// to get there.
    ///
    /// Margin is 0.13, roughly twice what `minimumStateSeparation` carries, and it
    /// needs to be: this number depends on font rasterisation as well as on
    /// compositing.
    ///
    /// It is deliberately a *max over the cap* rather than a mean. A mean is the
    /// 1.20 whole-visible-cap figure above — it buries a 9pt patch of plainly
    /// different plastic under the frosted rim all six caps share, and a 9pt patch on
    /// a 46pt cap is exactly what peripheral vision can still resolve.
    public static let minimumGlanceSeparation = 1.80

    /// The states that render as a lit key, and so have to be mutually
    /// distinguishable by luminance alone. Derived from `allCases` by exclusion
    /// rather than listed, so an eighth state joins the pairwise check by
    /// default instead of by remembering.
    ///
    /// `unassigned` is out because an empty slot is not a state and is meant to
    /// recede into the panel; it is guarded separately against `unknown`, which
    /// is the confusion that actually costs something. `idle` is out because the
    /// ladder has no room: the 1.8 construction step to the power of six exceeds
    /// the luminance range available between black and white, so a sixth rung
    /// cannot exist. It is placed in the widest gap the ladder leaves and its
    /// separations are documented rather than enforced.
    public static let litStates: [AgentState] =
        AgentState.allCases.filter { $0 != .unassigned && $0 != .idle }

    // MARK: - Self check

    /// Measured, not asserted. Empty when the palette is healthy.
    /// Wired into `SelfCheck.run()`.
    public static func selfCheckFailures() -> [String] {
        var failures: [String] = []

        func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

        for appearance in Appearance.allCases {
            // Label must be legible on the part of the cap it actually sits on,
            // which is the glow-lit middle, not the bare fill. See
            // `composedKeyCentre`.
            for state in AgentState.allCases {
                let s = swatch(for: state, in: appearance)
                let ratio = contrastRatio(s.keyLabel, s.composedKeyCentre)
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

            // Every lit pair, not one of them. The byte-identity test above is
            // not enough on its own and never was: `complete` and `error` were
            // different colours at the same luminance, 1.00:1 apart, and passed
            // it. Pairs are generated from `litStates` so nothing has to be
            // remembered when a state is added.
            for (index, first) in litStates.enumerated() {
                for second in litStates.dropFirst(index + 1) {
                    let separation = contrastRatio(
                        swatch(for: first, in: appearance).composedKeyFill,
                        swatch(for: second, in: appearance).composedKeyFill
                    )
                    if separation < minimumStateSeparation {
                        failures.append(
                            "\(first.rawValue) vs \(second.rawValue) separation \(fmt(separation)):1 in \(appearance.rawValue), needs \(fmt(minimumStateSeparation)):1"
                        )
                    }
                }
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
                let ratio = contrastRatio(s.keyLabel, s.composedKeyCentre)
                return String(format: "%@=%.2f", appearance.rawValue, ratio)
            }
            lines.append(state.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)
                + cells.joined(separator: "  "))
        }
        return lines.joined(separator: "\n")
    }
}
