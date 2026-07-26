import AppKit
import SwiftUI

/// The configuration surface for the two custom command keys and the four pad
/// presets. Six rows, one editor, and one thing it insists on saying out loud:
/// **which layer each binding came from.**
///
/// That is the reason this view exists in the shape it does. With global defaults
/// and per-project overrides resolved project-first, the question a user actually
/// arrives with is not "what is bound to pad up" — they can feel that by pressing
/// it — but "why is it doing *that* here and something else in my other repo".
/// A list showing only the effective binding cannot answer it. So every row wears
/// its layer as a chip and spells the resolution out in words, and a binding that
/// is shadowing something says what it shadowed.
///
/// Colours come from `StateColors`, sizes from `layout.fontSize(_:)`, which clamps
/// at 9pt. Reduce Transparency swaps material for a solid fill and thickens edges;
/// Reduce Motion drops the selection animation. Every control is a stock
/// `Button`, `Picker` or `TextField`, so Tab reaches all of them, Space and Return
/// fire them, and the button and field traits arrive for free — a custom control
/// here would mean re-earning keyboard access that AppKit already provides.
public struct KeyMapEditorView: View {

    // MARK: - Layer presentation (pure)

    /// Layers borrow the state palette rather than inventing colours, because
    /// `StateColors` is the only place a colour is allowed to live and every
    /// swatch in it is already contrast-measured.
    ///
    /// The mapping is not arbitrary. `unassigned` is specified as unlit and
    /// recessed, which is exactly what "nothing has been configured here" should
    /// look like. `idle` is the lit-but-quiet swatch, for a global default that is
    /// present and not competing. `running` is the loudest of the three, for the
    /// project override that is actively winning — the one a surprised user is
    /// looking for.
    public nonisolated static func swatchState(for layer: KeyMapStore.Layer) -> AgentState {
        switch layer {
        case .project: .running
        case .global: .idle
        case .builtIn: .unassigned
        }
    }

    /// Short text for the chip. Paired with the colour rather than replacing it,
    /// per the rule that no status on this panel is ever hue-only.
    public nonisolated static func chipLabel(for layer: KeyMapStore.Layer) -> String {
        switch layer {
        case .project: "project"
        case .global: "global"
        case .builtIn: "default"
        }
    }

    /// The whole row as one sentence, in the same order the row reads visually.
    /// VoiceOver gets the layer and the explanation verbatim — a screen-reader
    /// user needs to know a binding is a project override exactly as much as a
    /// sighted one does, so both texts are built from this.
    public nonisolated static func accessibilityLabel(
        _ binding: KeyMapStore.ResolvedBinding
    ) -> String {
        "\(binding.target.label): \(binding.preset.name), "
            + "\(binding.preset.action.kind.label) \"\(binding.preset.action.text)\". "
            + "\(binding.explanation)."
    }

    /// Why a layer cannot be edited right now, or `nil`. The project layer is the
    /// interesting case: with no repo in context there is nowhere to put an
    /// override, and saying so beats a control that accepts input and drops it.
    public nonisolated static func unavailableReason(
        layer: KeyMapStore.Layer, projectPath: String?
    ) -> String? {
        if !layer.isEditable {
            return "Built-in defaults are part of the app. Edit your global defaults instead."
        }
        if layer == .project, projectPath?.isEmpty ?? true {
            return "No project is in context, so there is nowhere to store a project override. "
                + "Bind a key to a session in a repo first."
        }
        return nil
    }

    /// Reduce Motion: the selection change still happens, it just arrives instantly.
    public nonisolated static func selectionAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.15)
    }

    // MARK: - State

    private let layout: PanelLayout
    /// The repo the panel is currently working in, or `nil` when there is none.
    /// Drives which project layer is being edited and resolved against.
    private let projectPath: String?

    @State private var store: KeyMapStore
    @State private var selected: KeyMapTarget
    /// Which layer edits are written to. Defaults to global, per PLAN.md: the
    /// common case is one setting that follows the user across repos, and a
    /// project override should be a deliberate choice rather than the default one.
    @State private var editLayer: KeyMapStore.Layer = .global

    @State private var draftName = ""
    @State private var draftKind: PresetAction.Kind = .prompt
    @State private var draftText = ""
    /// Why the last save was refused. Shown, never swallowed.
    @State private var rejection: String?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// The store is injected rather than created here: a view that opens a file in
    /// its own initialiser cannot be rendered in a preview or checked without one.
    public init(
        store: KeyMapStore,
        projectPath: String? = nil,
        layout: PanelLayout = .regular
    ) {
        self.layout = layout
        self.projectPath = projectPath
        _store = State(initialValue: store)
        _selected = State(initialValue: KeyMapTarget.allCases.first ?? .pad(.up))
    }

    // MARK: - Body

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            rows
            Divider()
            editor
            if !store.warnings.isEmpty { warningBox(store.warnings.last ?? "") }
        }
        .padding(14)
        .frame(width: 420, alignment: .leading)
        .background(surface)
        .animation(Self.selectionAnimation(reduceMotion: reduceMotion), value: selected)
        .onAppear { loadDraft() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Keys and presets")
                .font(.system(size: layout.fontSize(13), weight: .semibold))
            Text(
                "Bindings resolve project first, then your global defaults, then the "
                    + "built-in default. Each row says which one it came from."
            )
            .font(.system(size: layout.fontSize(10)))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Picker("Editing", selection: $editLayer) {
                    ForEach(KeyMapStore.Layer.allCases.filter(\.isEditable), id: \.self) { layer in
                        Text(Self.chipLabel(for: layer)).tag(layer)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityHint("Which layer your edits are written to.")

                Spacer(minLength: 0)

                Button("Reset all in \(Self.chipLabel(for: editLayer))") {
                    store.resetLayer(editLayer, projectPath: projectPath)
                    loadDraft()
                }
                .disabled(layerIsEmpty || !canEdit)
                .accessibilityHint(
                    "Removes every binding from the \(Self.chipLabel(for: editLayer)) layer, "
                        + "so each key falls back to the layer beneath it."
                )
            }
            .font(.system(size: layout.fontSize(11)))

            if let reason = Self.unavailableReason(layer: editLayer, projectPath: projectPath) {
                Text(reason)
                    .font(.system(size: layout.fontSize(10)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Rows

    /// A plain `VStack` of `Button`s rather than a `List` with selection: this is
    /// six fixed rows inside a panel, and a Button gives keyboard focus, Space and
    /// Return, the button trait and a hover target with no configuration at all.
    private var rows: some View {
        VStack(spacing: 4) {
            ForEach(store.allResolved(projectPath: projectPath), id: \.target) { binding in
                Button {
                    selected = binding.target
                    loadDraft()
                } label: {
                    row(binding)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.accessibilityLabel(binding))
                .accessibilityHint("Edit this binding.")
                .accessibilityAddTraits(selected == binding.target ? [.isSelected] : [])
            }
        }
    }

    private func row(_ binding: KeyMapStore.ResolvedBinding) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let isSelected = selected == binding.target
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.glyph(binding.target))
                .font(.system(size: layout.fontSize(11), weight: .medium))
                .frame(width: layout.fontSize(14), alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(binding.target.label)
                        .font(.system(size: layout.fontSize(11), weight: .medium))
                    Text(binding.preset.name)
                        .font(.system(size: layout.fontSize(11)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(binding.preset.action.stdinText)
                    .font(.system(size: layout.fontSize(9), design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            chip(binding.layer)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .contentShape(shape)
        .background(shape.fill(Color.accentColor.opacity(isSelected ? 0.16 : 0)))
        .overlay(
            shape.strokeBorder(
                Color.accentColor.opacity(isSelected ? 1 : 0),
                lineWidth: reduceTransparency ? 1.5 : 1
            )
        )
    }

    /// Colour and word together. The chip is never the only signal — the sentence
    /// under the editor repeats it in full.
    private func chip(_ layer: KeyMapStore.Layer) -> some View {
        let swatch = swatch(Self.swatchState(for: layer))
        return Text(Self.chipLabel(for: layer))
            .font(.system(size: layout.fontSize(9), weight: .semibold))
            .foregroundStyle(swatch.keyLabel.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    swatch.keyFill.color.opacity(reduceTransparency ? 1 : swatch.fillOpacity)
                )
            )
            .overlay(Capsule().strokeBorder(
                swatch.keyEdge.color.opacity(0.6),
                lineWidth: reduceTransparency ? 1.5 : 0.5
            ))
    }

    // MARK: Editor

    private var editor: some View {
        let binding = store.resolved(selected, projectPath: projectPath)
        return VStack(alignment: .leading, spacing: 8) {
            Text(selected.label.uppercased())
                .font(.system(size: layout.fontSize(9), weight: .semibold))
                .foregroundStyle(.tertiary)

            if let binding {
                Text(binding.explanation)
                    .font(.system(size: layout.fontSize(10)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField("Name", text: $draftName)
                .font(.system(size: layout.fontSize(11)))
                .accessibilityLabel("Preset name")

            Picker("Sends", selection: $draftKind) {
                ForEach(PresetAction.Kind.allCases, id: \.self) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .font(.system(size: layout.fontSize(11)))
            .accessibilityHint(
                "A preset sends text to the session. It cannot run a shell command."
            )

            // Single line on purpose. A multi-line field would let the user type
            // the exact carriage return that `KeyMapStore.rejection` has to refuse,
            // so the widget cannot produce the input the validator rejects.
            TextField(
                draftKind == .prompt ? "Prompt text" : "Command name, without the slash",
                text: $draftText
            )
            .font(.system(size: layout.fontSize(11), design: .monospaced))
            .accessibilityLabel(draftKind == .prompt ? "Prompt text" : "Slash command name")

            if let rejection { warningBox(rejection) }

            HStack(spacing: 8) {
                Button("Save to \(Self.chipLabel(for: editLayer))", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canEdit)
                Button("Reset in \(Self.chipLabel(for: editLayer))") {
                    store.reset(selected, layer: editLayer, projectPath: projectPath)
                    rejection = nil
                    loadDraft()
                }
                .disabled(!canEdit || store.layerBindings(editLayer, projectPath: projectPath)[selected] == nil)
                .accessibilityHint("Falls back to the layer beneath, rather than clearing the key.")
                Spacer(minLength: 0)
            }
            .font(.system(size: layout.fontSize(11)))
        }
    }

    // MARK: Behaviour

    private var canEdit: Bool {
        Self.unavailableReason(layer: editLayer, projectPath: projectPath) == nil
    }

    private var layerIsEmpty: Bool {
        store.layerBindings(editLayer, projectPath: projectPath).isEmpty
    }

    /// Seeds the fields from the *effective* binding, not from the layer being
    /// edited. Starting from what the key currently does is what a user expects
    /// when they open the editor to tweak it, and it makes "copy the global into a
    /// project override" a one-click job.
    private func loadDraft() {
        guard let binding = store.resolved(selected, projectPath: projectPath) else { return }
        draftName = binding.preset.name
        draftKind = binding.preset.action.kind
        draftText = binding.preset.action.text
    }

    private func save() {
        let preset = Preset(
            name: draftName,
            action: PresetAction(kind: draftKind, text: draftText)
        )
        rejection = store.set(preset, for: selected, layer: editLayer, projectPath: projectPath)
    }

    // MARK: Chrome

    private var appearance: StateColors.Appearance {
        AgentKeyView.appearance(
            colorScheme: colorScheme,
            increasedContrast: colorSchemeContrast == .increased
        )
    }

    private func swatch(_ state: AgentState) -> StateColors.StateSwatch {
        StateColors.swatch(for: state, in: appearance)
    }

    /// Reduce Transparency: opaque surface plus an edge you can actually find.
    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            shape.fill(reduceTransparency
                ? AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
                : AnyShapeStyle(.ultraThinMaterial))
            shape.strokeBorder(.quaternary, lineWidth: reduceTransparency ? 1.5 : 0.5)
        }
    }

    /// Wears the `needsInput` swatch: this box is where the panel asks the user to
    /// deal with something, which is what amber means everywhere else here.
    private func warningBox(_ text: String) -> some View {
        let swatch = swatch(.needsInput)
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: layout.fontSize(10), weight: .bold))
            Text(text)
                .font(.system(size: layout.fontSize(10), weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(swatch.keyLabel.color)
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(swatch.keyFill.color.opacity(reduceTransparency ? 1 : swatch.fillOpacity))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(swatch.keyEdge.color.opacity(0.7),
                              lineWidth: reduceTransparency ? 1.5 : 0.5)
        )
        .accessibilityLabel("Warning: \(text)")
    }

    /// SF Symbols 1.0 names, resolved through `NSImage` by the self check rather
    /// than trusted.
    nonisolated static func glyph(_ target: KeyMapTarget) -> String {
        switch target {
        case .command(.custom1): "1.circle"
        case .command(.custom2): "2.circle"
        case .command: "square.circle"
        case .pad(.up): "arrow.up"
        case .pad(.right): "arrow.right"
        case .pad(.down): "arrow.down"
        case .pad(.left): "arrow.left"
        case .pad(.center): "square.grid.2x2"
        }
    }

    // MARK: - Self check

    /// Empty when healthy. Wire into `SelfCheck.run()` with:
    ///
    ///     failures += KeyMapEditorView.selfCheckFailures().map { "keymapui: \($0)" }
    ///
    /// Covers what the store's own check cannot see: that the three layers are
    /// visually and verbally distinguishable, that every row has a glyph that
    /// exists, and that no label routes around the 9pt floor.
    public nonisolated static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // Layers must be told apart by word and by fill, in every appearance. A
        // chip that reads the same for global and project makes the layer column
        // decorative, which is the one thing this view exists to avoid.
        let layers = KeyMapStore.Layer.allCases
        for (index, first) in layers.enumerated() {
            check("\(first.rawValue) has no chip label", !chipLabel(for: first).isEmpty)
            check("\(first.rawValue) has no explanatory label", !first.label.isEmpty)
            for second in layers[(index + 1)...] {
                check(
                    "\(first.rawValue) and \(second.rawValue) share a chip label",
                    chipLabel(for: first) != chipLabel(for: second)
                )
                check(
                    "\(first.rawValue) and \(second.rawValue) share a swatch",
                    swatchState(for: first) != swatchState(for: second)
                )
                // Three distinct states means three distinct fills, which
                // `StateColors.selfCheckFailures()` already guarantees across
                // every appearance. Asserted here anyway so the dependency is
                // visible: if that guarantee ever weakens, the layer column
                // quietly becomes decoration.
                for appearance in StateColors.Appearance.allCases {
                    let a = StateColors.swatch(for: swatchState(for: first), in: appearance)
                    let b = StateColors.swatch(for: swatchState(for: second), in: appearance)
                    if a.composedKeyFill == b.composedKeyFill {
                        failures.append(
                            "\(first.rawValue) and \(second.rawValue) chips share a fill in \(appearance.rawValue)"
                        )
                    }
                }
            }
        }

        // Every remappable target renders with a real glyph.
        for target in KeyMapTarget.allCases {
            let glyph = glyph(target)
            if glyph.isEmpty {
                failures.append("\(target.wireID) has no glyph")
            } else if NSImage(systemSymbolName: glyph, accessibilityDescription: nil) == nil {
                failures.append("\(target.wireID) glyph \"\(glyph)\" does not resolve as an SF Symbol")
            }
        }

        // The row sentence must carry the binding, the layer explanation, and the
        // action — asserted on the string, because a boolean "mentions the layer"
        // would pass with an empty one.
        let projectWin = KeyMapStore.resolve(
            .pad(.up), projectPath: "/Users/x/work/ledger",
            projects: ["/Users/x/work/ledger": [.pad(.up): Preset(name: "repo review", action: .prompt("review it"))]],
            global: [.pad(.up): Preset(name: "global review", action: .prompt("review the PR"))]
        )
        guard let projectWin else {
            return failures + ["a fully populated resolution came back nil"]
        }
        let spoken = accessibilityLabel(projectWin)
        check("the row sentence omits the key", spoken.contains(KeyMapTarget.pad(.up).label))
        check("the row sentence omits the preset name", spoken.contains("repo review"))
        check("the row sentence omits what the key sends", spoken.contains("review it"))
        check("the row sentence omits the layer explanation", spoken.contains(projectWin.explanation))
        check("the row sentence hides that a global default is being overridden",
              spoken.contains("overriding"))

        guard let builtIn = KeyMapStore.resolve(
            .pad(.up), projectPath: nil, projects: [:], global: [:]
        ) else {
            return failures + ["an unconfigured key resolved to nothing"]
        }
        let builtInSpoken = accessibilityLabel(builtIn)
        check("an unconfigured key has no sentence", !builtInSpoken.isEmpty)
        check("a project override and a built-in default read alike", builtInSpoken != spoken)
        check(
            "an unconfigured key does not say nothing is configured",
            builtInSpoken.contains("nothing has been configured")
        )

        // The project layer must be refused, with a reason, when there is no repo.
        for path in [nil, ""] as [String?] {
            let reason = unavailableReason(layer: .project, projectPath: path)
            check("editing the project layer with no project open was allowed", reason != nil)
            check("refusing the project layer gave no reason", !(reason?.isEmpty ?? true))
        }
        check(
            "the project layer is refused even with a project open",
            unavailableReason(layer: .project, projectPath: "/Users/x/work/ledger") == nil
        )
        check(
            "the global layer is refused",
            unavailableReason(layer: .global, projectPath: nil) == nil
        )
        check(
            "the built-in layer is offered as editable",
            unavailableReason(layer: .builtIn, projectPath: "/x") != nil
        )

        // Reduce Motion snaps.
        check("Reduce Motion still animates the selection", selectionAnimation(reduceMotion: true) == nil)
        check("the selection does not animate when motion is allowed",
              selectionAnimation(reduceMotion: false) != nil)

        // Nothing routes around the 9pt floor at the compact scale.
        for base in [9, 10, 11, 13, 14] as [CGFloat]
        where PanelLayout.compact.fontSize(base) < PanelLayout.minimumFontSize {
            failures.append("base \(base)pt resolves under the \(PanelLayout.minimumFontSize)pt floor")
        }

        return failures
    }
}
