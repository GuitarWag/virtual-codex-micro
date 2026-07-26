import AppKit
import SwiftUI

/// The colour check, run against rendered pixels instead of against the palette
/// model.
///
/// `StateColors.selfCheckFailures()` measures `composedKeyFill` — fill blended
/// onto the backdrop at its own opacity. That is a model of the cap, and it is
/// structurally blind to every layer `AgentKeyView` draws *on top* of the fill:
/// the radial state glow, the milky `plasticShell` frost, the `moulding`
/// highlight and shade. Those layers are exactly where a contrast regression
/// comes from, and one did: a full-face white frost took `error`'s glyph to
/// 3.12:1 and squeezed three lit pairs under the floor while the model-based suite
/// reported ok throughout. Re-applying that frost with this check in place trips
/// fourteen assertions — six glyphs and eight pairs — while `VCM_SELFTEST=1` alone
/// still prints "ok", so the blind spot is real and this is the thing that sees it.
///
/// So this samples the real thing. The whole panel is rendered per appearance
/// through `ImageRenderer` — the same path `OffscreenRender` uses, needing no
/// Screen Recording permission — and each agent cap is measured where
/// `PanelLayout` puts it, on the real plate, under the real case underglow. Three
/// numbers come out of the bitmap:
///
/// - **glyph ink against the cap it sits on.** Checked against
///   `StateColors.minimumLabelContrast`.
/// - **the slot numeral against its corner.** Same floor. It is drawn from a
///   literal rather than a `StateColors` token, which is exactly why nothing used
///   to measure it.
/// - **cap against cap, every lit pair.** Checked against
///   `StateColors.minimumStateSeparation`.
///
/// All three walk `AgentState.allCases` / `StateColors.litStates`, so an eighth
/// state is measured without anyone remembering to add it.
///
/// ## Why this is opt-in rather than part of the default self-check
///
/// Not for speed. The whole pass costs about 0.15s of CPU on this machine, which
/// is measured and is nothing. It is opt-in because of what it depends on:
///
/// - **A full render of the panel.** `SelfCheck.run()` is called before
///   `NSApplication` exists, on purpose, and everything else it runs is pure —
///   this is the one entry that builds a view tree and rasterises it.
/// - **The rasteriser.** These numbers are a property of how this OS composites,
///   not only of the palette. That is the point — it is why the check can see
///   things the model cannot — but it also means a different macOS version or
///   display setup can move them, and a check that fails for that reason is a
///   check people learn to ignore. `Scripts/check-render.sh` already carries the
///   same caveat for the same reason.
///
/// So it runs where a failure gets looked at rather than everywhere: wired into
/// `Scripts/verify.sh`, and available by hand as
///
///     VCM_SELFTEST=1 VCM_PIXELCHECK=1 ./.build/debug/VirtualCodexMicro
///     VCM_SELFTEST=1 VCM_PIXELCHECK=report ...    # also prints every ratio
///
/// The model-based checks stay exactly where they are. They are pure, they catch
/// a bad palette edit anywhere, and they cover all four appearances; this is
/// additional coverage of the compositing they cannot see.
@MainActor
enum PixelCheck {

    // MARK: - Sample geometry
    //
    // Radii are fractions of the cap's side, measured from the cap's centre, and
    // they follow what `AgentKeyView` actually draws: the glyph is 17pt on a 46pt
    // cap so its mark lives inside r ≈ 0.19·side, and `plasticShell` is
    // deliberately clear out to r ≈ 0.19·side for exactly that reason.
    //
    // There are two face bands, not one, because the two questions are different
    // and conflating them was a real mistake in the first version of this file:

    /// The mark itself.
    private static let inkRadius = 0.19

    /// **The state-bearing centre**: a thin ring just outside the mark, where the
    /// frost is still nearly clear. Both enforced checks measure here — label
    /// contrast against it, and state-to-state separation between two of them.
    private static let centreInner = 0.21
    private static let centreOuter = 0.26

    /// **The visible cap**: out to near the edge, which is what a glance
    /// integrates. Measured and reported, deliberately **not** enforced, and the
    /// reason is the whole argument for where the floor belongs.
    ///
    /// The M1 review argued the floor should sit here rather than on the centre,
    /// because the centre is the one part of the cap the frost was designed to keep
    /// clear and measuring it flatters the ladder. The first half is right — see
    /// `report()`, where the visible cap collapses to 1.17–1.77 against a modelled
    /// 1.81–11.0, which is a real defect and is on the board. But enforcing there
    /// would produce a check that cannot fail. Re-running the historical full-face
    /// frost regression — the one this file exists to catch — moved the visible cap
    /// by nothing at all, while the centre moved plainly:
    ///
    ///     pair                     visible cap      centre
    ///     dark  error/unknown      1.17 → 1.16      1.61 → 1.44
    ///     light running/error      1.24 → 1.23      1.57 → 1.26
    ///     light complete/error     1.43 → 1.41      1.67 → 1.46
    ///
    /// The visible cap is saturated: it is already dominated by the shared white
    /// rim, so pouring more white over the middle barely moves its median. A floor
    /// set low enough to pass today would let that entire regression through. The
    /// centre is where the states actually differ, so it is where a guard has any
    /// power, and the sabotage numbers above are the evidence.
    ///
    /// Stops at 0.45, not 0.50, so the edge stroke and the antialiased silhouette
    /// stay out of it.
    private static let capInner = 0.21
    private static let capOuter = 0.45

    /// Ink is read as a percentile rather than an extreme so a single stray
    /// antialiased pixel cannot stand in for the mark, and so a thin stroke's
    /// partially covered edge does not get mistaken for its core.
    private static let inkPercentile = 0.05

    /// Light and dark only, and not for want of trying: `AgentKeyView` picks its
    /// appearance from `colorSchemeContrast`, which is **read-only** in the
    /// SwiftUI environment, and `NSAppearance(named: .accessibilityHighContrastAqua)`
    /// does not set it. Measured, not assumed — rendering under that appearance
    /// produced a cap still translucent enough to track the backdrop, i.e. still
    /// on the plain palette, so the two extra rows compared a normal-contrast
    /// render against an increased-contrast model and reported ratios that were
    /// not about anything. A number that looks like evidence and is not is worse
    /// than a gap, so the gap is here in writing instead.
    ///
    /// `StateColors.selfCheckFailures()` still covers all four appearances on the
    /// model, which is where the increased-contrast palette gets its coverage.
    static let renderableAppearances: [StateColors.Appearance] = [.light, .dark]

    /// The one rendered glyph contrast that does not reach
    /// `StateColors.minimumLabelContrast`, recorded with the value measured today
    /// and held as a **ceiling**: it may improve, it may not slip.
    ///
    /// `minimumLabelContrast` is 4.5 because that is WCAG 2.1 AA for normal text,
    /// so unlike `minimumStateSeparation` it is not ours to lower — see that
    /// property for the one that was. `error` in light cannot reach it inside the
    /// current palette, and the sweep that proves it is worth keeping: `error`'s
    /// white glyph sits on a cap whose centre is the state glow at 0.85, and
    /// darkening that glow to lift the glyph (3.48 → 3.76 → 3.99 → 4.23) drove
    /// `running` vs `error` down in lockstep (1.59 → 1.46 → 1.37 → 1.29). Red
    /// cannot exceed 0.21 relative luminance while staying red, `running` is
    /// pinned under it by blue's 0.07 ceiling, and there is not room for both a
    /// legible white mark and a rung between them. The fix is a glyph treatment
    /// that does not depend on the cap underneath it — an outline, or ink flipped
    /// to dark with the ladder rebuilt around it — which is a restyle, not a hex
    /// edit, and belongs on the board rather than in this diff.
    ///
    /// Anything not listed here is held to the full 4.5, including a state added
    /// later. Keep this dictionary at one entry if you can.
    private static let knownGlyphShortfall: [String: Double] = [
        "error.light": 3.48,
    ]

    /// Slack on the recorded ceilings, for a machine that composites a shade
    /// differently. Small enough that a real regression still trips it — the
    /// sweep above moved this number by 0.30 for a barely visible glow change.
    private static let shortfallTolerance = 0.08

    // MARK: - Measurement

    struct Measurement: Sendable {
        let state: AgentState
        let appearance: StateColors.Appearance
        /// Median colour of the visible cap, glyph excluded. Basis for separation.
        let cap: StateColors.RGB
        /// Median colour of the ring the glyph sits in. Basis for label contrast.
        let surround: StateColors.RGB
        /// The glyph's own ink.
        let ink: StateColors.RGB
        /// The slot numeral's ink, and the corner it sits in.
        let numeralInk: StateColors.RGB
        let numeralCorner: StateColors.RGB
        /// What the model predicted for the same cap, for comparison.
        let modelFill: StateColors.RGB

        var labelContrast: Double { StateColors.contrastRatio(ink, surround) }
        var numeralContrast: Double { StateColors.contrastRatio(numeralInk, numeralCorner) }
        var modelLabelContrast: Double {
            StateColors.contrastRatio(
                StateColors.swatch(for: state, in: appearance).keyLabel, modelFill
            )
        }
    }

    /// Two panel renders per appearance, covering all seven states across the six
    /// slots, sampled at the cap frames `PanelLayout` puts them at.
    ///
    /// **The whole panel, not a cap on a synthetic backdrop.** The first version of
    /// this file rendered one `AgentKeyView` over `StateColors.panelBackdrop(...)`,
    /// and the M1 review found the flaw: `panelBackdrop(.light)` is 0.810 while the
    /// plate `DeviceChrome` actually draws measures 1.000, and the dark plate is a
    /// gradient running 0.179 → 0.024 down its own height. There is no single
    /// backdrop value, so compositing a translucent cap against one produced a cap
    /// that does not exist. Rendering the real panel removes the question — the cap
    /// sits on the real plate, under the real case underglow, beside its real
    /// neighbours and their spill.
    static func measurements() -> [Measurement] {
        var result: [Measurement] = []
        let layout = PanelLayout.regular

        for appearance in renderableAppearances {
            for slots in slotPlans {
                guard let rep = render(slots: slots, appearance: appearance, layout: layout)
                else { continue }
                let scale = Double(rep.pixelsWide) / Double(layout.panelSize.width)

                // Sorted, not the dictionary's own order: `Dictionary` iteration
                // is seeded per process, and letting it leak out here made the
                // report shuffle between runs — which reads exactly like a flaky
                // check even when every measured value is identical.
                for (slot, state) in slots.sorted(by: { $0.key < $1.key }) {
                    let frame = layout.agentKeyFrame(slot)
                    let side = Double(frame.width)
                    let centre = CGPoint(x: frame.midX, y: frame.midY)

                    guard
                        let cap = pixel(rep, scale, centre, side, capInner, capOuter, 0.5),
                        let surround = pixel(
                            rep, scale, centre, side, centreInner, centreOuter, 0.5
                        )
                    else { continue }

                    // Which side of the cap the ink sits on is the palette's
                    // declaration, not something to discover from the pixels:
                    // taking whichever extreme contrasts more would report a
                    // bright frost specular as the glyph and hide the exact
                    // regression this file exists to catch.
                    let swatch = StateColors.swatch(for: state, in: appearance)
                    let inkIsDark = StateColors.relativeLuminance(swatch.keyLabel)
                        < StateColors.relativeLuminance(surround)
                    guard let ink = pixel(
                        rep, scale, centre, side, 0, inkRadius,
                        inkIsDark ? inkPercentile : 1 - inkPercentile
                    ) else { continue }

                    // The slot numeral, in the top-leading corner. Sampled in its
                    // own little box because it is nowhere near the centre and the
                    // frost takes that corner to near-white on every state.
                    let corner = CGPoint(
                        x: frame.minX + frame.width * 0.20,
                        y: frame.minY + frame.height * 0.20
                    )
                    guard
                        let numeralInk = pixel(rep, scale, corner, side, 0, 0.13, inkPercentile),
                        let numeralCorner = pixel(rep, scale, corner, side, 0, 0.13, 0.9)
                    else { continue }

                    result.append(Measurement(
                        state: state, appearance: appearance,
                        cap: cap, surround: surround, ink: ink,
                        numeralInk: numeralInk, numeralCorner: numeralCorner,
                        modelFill: swatch.composedKeyFill
                    ))
                }
            }
        }
        return result
    }

    /// Seven states over six slots, so it takes two panels. Built from `allCases`
    /// by chunking rather than written out, so an eighth state lands in a third
    /// panel on its own instead of being silently dropped.
    private static var slotPlans: [[Int: AgentState]] {
        let perPanel = PanelLayout.agentKeyCount
        return stride(from: 0, to: AgentState.allCases.count, by: perPanel).map { start in
            let chunk = AgentState.allCases[start..<min(start + perPanel, AgentState.allCases.count)]
            return Dictionary(uniqueKeysWithValues: chunk.enumerated().map { ($0.offset, $0.element) })
        }
    }

    // MARK: - Checks

    /// Empty when the rendered caps hold the declared floors. Same two
    /// invariants `StateColors.selfCheckFailures()` asserts, measured on pixels.
    static func failures() -> [String] {
        var failures: [String] = []
        func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

        let measured = measurements()
        let expected = renderableAppearances.count * AgentState.allCases.count
        guard measured.count == expected else {
            return ["rendered only \(measured.count) of \(expected) caps — the check did not run"]
        }

        var faces: [StateColors.Appearance: [AgentState: StateColors.RGB]] = [:]
        for m in measured {
            faces[m.appearance, default: [:]][m.state] = m.surround

            // The slot numeral. It is on the cap, it is the only thing addressing
            // the key, and until now it was outside every assertion — it is drawn
            // from a literal rather than a `StateColors` token, so neither the
            // model check nor the first version of this one could see it.
            if m.numeralContrast < StateColors.minimumLabelContrast {
                failures.append(
                    "\(m.state.rawValue) slot numeral contrast \(fmt(m.numeralContrast)):1 in "
                    + "\(m.appearance.rawValue), needs \(fmt(StateColors.minimumLabelContrast)):1"
                )
            }

            guard m.labelContrast < StateColors.minimumLabelContrast else { continue }

            // Below the floor. Either it is a shortfall we have written down, in
            // which case it must not get any worse, or it is new.
            if let ceiling = knownGlyphShortfall["\(m.state.rawValue).\(m.appearance.rawValue)"] {
                if m.labelContrast < ceiling - shortfallTolerance {
                    failures.append(
                        "\(m.state.rawValue) rendered glyph contrast fell from a recorded "
                        + "\(fmt(ceiling)):1 to \(fmt(m.labelContrast)):1 in \(m.appearance.rawValue)"
                    )
                }
            } else {
                failures.append(
                    "\(m.state.rawValue) rendered glyph contrast \(fmt(m.labelContrast)):1 in "
                    + "\(m.appearance.rawValue), needs \(fmt(StateColors.minimumLabelContrast)):1 "
                    + "(model says \(fmt(m.modelLabelContrast)):1)"
                )
            }
        }

        // litStates, so a new lit state joins the pairwise sweep by itself.
        for appearance in renderableAppearances {
            guard let byState = faces[appearance] else { continue }
            for (index, first) in StateColors.litStates.enumerated() {
                for second in StateColors.litStates.dropFirst(index + 1) {
                    guard let a = byState[first], let b = byState[second] else { continue }
                    let separation = StateColors.contrastRatio(a, b)
                    if separation < StateColors.minimumStateSeparation {
                        let model = StateColors.contrastRatio(
                            StateColors.swatch(for: first, in: appearance).composedKeyFill,
                            StateColors.swatch(for: second, in: appearance).composedKeyFill
                        )
                        failures.append(
                            "\(first.rawValue) vs \(second.rawValue) rendered separation "
                            + "\(fmt(separation)):1 in \(appearance.rawValue), needs "
                            + "\(fmt(StateColors.minimumStateSeparation)):1 (model says \(fmt(model)):1)"
                        )
                    }
                }
            }
        }

        return failures
    }

    /// Every rendered number next to its modelled counterpart. Read this when a
    /// layer over the fill changes — it is the only place the cost shows up.
    static func report() -> String {
        var lines: [String] = []
        let measured = measurements()
        func pad(_ s: String, _ width: Int) -> String {
            s.padding(toLength: max(width, s.count), withPad: " ", startingAt: 0)
        }
        func fmt(_ v: Double) -> String { String(format: "%5.2f", v) }

        lines.append("glyph / numeral contrast on the rendered cap (glyph model in brackets)")
        for appearance in renderableAppearances {
            for m in measured where m.appearance == appearance {
                lines.append("  " + pad(m.state.rawValue, 12) + pad(appearance.rawValue, 8)
                    + "glyph " + fmt(m.labelContrast) + "  [" + fmt(m.modelLabelContrast) + "]"
                    + "   numeral " + fmt(m.numeralContrast))
            }
        }

        lines.append("")
        lines.append("lit pair separation: centre (enforced) | visible cap | [model]")
        for appearance in renderableAppearances {
            let rows = measured.filter { $0.appearance == appearance }
            let centres = Dictionary(uniqueKeysWithValues: rows.map { ($0.state, $0.surround) })
            let caps = Dictionary(uniqueKeysWithValues: rows.map { ($0.state, $0.cap) })
            for (index, first) in StateColors.litStates.enumerated() {
                for second in StateColors.litStates.dropFirst(index + 1) {
                    guard let a = centres[first], let b = centres[second],
                          let ca = caps[first], let cb = caps[second] else { continue }
                    let model = StateColors.contrastRatio(
                        StateColors.swatch(for: first, in: appearance).composedKeyFill,
                        StateColors.swatch(for: second, in: appearance).composedKeyFill
                    )
                    lines.append("  " + pad(appearance.rawValue, 8) + pad(first.rawValue, 12)
                        + pad(second.rawValue, 12)
                        + fmt(StateColors.contrastRatio(a, b))
                        + " | " + fmt(StateColors.contrastRatio(ca, cb))
                        + " | [" + fmt(model) + "]")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Render

    /// `ImageRenderer`, **not** `NSHostingView.cacheDisplay`.
    ///
    /// This file originally used `cacheDisplay(in:to:)` and the numbers it
    /// produced were wrong in the one direction that matters: the M1 review proved
    /// that path can drop a blurred layer outright, and on this panel the case
    /// underglow and each cap's `spill` are made of blur. A measuring tool that
    /// silently omits a layer is worse than no tool, because it reports confident
    /// numbers for an image the user never sees. `OffscreenRender` moved for the
    /// same reason; this follows it so the check and the reference PNGs are looking
    /// at the same picture.
    ///
    /// Appearance is set through `\.colorScheme` rather than `NSAppearance`, which
    /// is what `ImageRenderer` honours.
    private static func render(
        slots: [Int: AgentState], appearance: StateColors.Appearance, layout: PanelLayout
    ) -> NSBitmapImageRep? {
        let sessions = slots.compactMapValues { state -> AgentSession? in
            // An unassigned slot must not be handed a session: it would start
            // naming one, which is the stale-binding failure the view guards.
            state == .unassigned ? nil : AgentSession(
                id: "pixel-\(state.rawValue)", backendID: "pixel",
                title: "pixel check", state: state
            )
        }
        let view = PanelRootView(
            coordinator: .demo(states: slots, sessions: sessions, capabilities: .observed),
            layout: layout
        )

        let renderer = ImageRenderer(
            content: view.environment(\.colorScheme, appearance.isDark ? .dark : .light)
        )
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(layout.panelSize)

        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    // MARK: - Sampling

    /// The pixel at `percentile` of luminance within an annulus centred on
    /// `centre` (a point in layout coordinates), radii given as fractions of
    /// `side`.
    ///
    /// A real pixel is returned rather than an average of the region: averaging
    /// two colours produces one that is on neither the cap nor the glyph, and the
    /// contrast of an invented colour is not evidence about anything.
    private static func pixel(
        _ rep: NSBitmapImageRep, _ scale: Double, _ centre: CGPoint, _ side: Double,
        _ innerFraction: Double, _ outerFraction: Double, _ percentile: Double
    ) -> StateColors.RGB? {
        let cx = Double(centre.x) * scale
        let cy = Double(centre.y) * scale
        let inner = innerFraction * side * scale
        let outer = outerFraction * side * scale

        var samples: [(luminance: Double, colour: StateColors.RGB)] = []
        let span = Int(outer.rounded(.up))
        for dy in -span...span {
            for dx in -span...span {
                let distance = (Double(dx) * Double(dx) + Double(dy) * Double(dy)).squareRoot()
                guard distance >= inner, distance <= outer else { continue }
                let x = Int(cx) + dx
                let y = Int(cy) + dy
                guard x >= 0, x < rep.pixelsWide, y >= 0, y < rep.pixelsHigh,
                      let colour = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                else { continue }
                let rgb = StateColors.RGB(
                    red: Double(colour.redComponent),
                    green: Double(colour.greenComponent),
                    blue: Double(colour.blueComponent)
                )
                samples.append((StateColors.relativeLuminance(rgb), rgb))
            }
        }
        guard !samples.isEmpty else { return nil }
        samples.sort { $0.luminance < $1.luminance }
        let index = min(samples.count - 1, max(0, Int(percentile * Double(samples.count - 1))))
        return samples[index].colour
    }
}
