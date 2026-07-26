import Foundation
import os

private let log = Logger(subsystem: "com.virtualcodexmicro.app", category: "keymap")

// MARK: - What can be remapped

/// The remappable targets: the two custom command slots and the four pad
/// directions. Nothing else is here on purpose — accept, reject, new session and
/// push-to-talk are fixed-meaning keys whose position and behaviour are the
/// muscle memory the panel sells, and the pad centre is the chooser rather than a
/// preset.
///
/// `wireID` is the on-disk key and it is a contract: rename a Swift case and the
/// string must stay. The enums are the source of the case list, so a direction
/// added to `PanelLayout.PadDirection` becomes remappable without an edit here.
public enum KeyMapTarget: Hashable, Sendable {
    case command(PanelLayout.CommandSlot)
    case pad(PanelLayout.PadDirection)

    /// The command slots the user may rebind. The other four are fixed.
    public static let remappableCommandSlots: [PanelLayout.CommandSlot] = [.custom1, .custom2]

    public static let allCases: [KeyMapTarget] =
        remappableCommandSlots.map(KeyMapTarget.command)
            + DirectionPadView.cardinals.map(KeyMapTarget.pad)

    public var wireID: String {
        switch self {
        case let .command(slot): "command.\(slot.rawValue)"
        case let .pad(direction): "pad.\(direction.rawValue)"
        }
    }

    /// `nil` for anything this build does not recognise, including a fixed
    /// command slot or the pad centre — a config file must not be able to rebind
    /// accept by naming it.
    public init?(wireID: String) {
        let parts = wireID.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "command":
            guard let slot = PanelLayout.CommandSlot(rawValue: String(parts[1])),
                  Self.remappableCommandSlots.contains(slot)
            else { return nil }
            self = .command(slot)
        case "pad":
            guard let direction = PanelLayout.PadDirection(rawValue: String(parts[1])),
                  direction != .center
            else { return nil }
            self = .pad(direction)
        default:
            return nil
        }
    }

    /// Shown in the editor and spoken by VoiceOver. Deliberately defined here
    /// rather than borrowed from `CommandKeyView.actionName` — that one is
    /// main-actor isolated, and one label source beats two that can drift.
    public var label: String {
        switch self {
        case .command(.custom1): "Custom key 1"
        case .command(.custom2): "Custom key 2"
        case let .command(slot): "Command key \(slot.rawValue)"
        case let .pad(direction): "Pad \(direction.rawValue)"
        }
    }
}

// MARK: - What a preset is

/// What a preset does when it fires.
///
/// **Two kinds, both of them text typed into a session's stdin. There is no
/// shell case, and that is the security decision, not an omission.**
///
/// A preset file is importable, which makes it untrusted input: "import this
/// preset pack" must not be a synonym for "run this script". Every existing
/// write path in this app is `AgentCommand.sendPrompt`, i.e. bytes on a PTY we
/// own, so nothing in the product needs `Process` — adding a `shell` case would
/// introduce code execution that only a config file uses, which is the whole
/// vulnerability in one line.
///
/// The chosen rule is **restriction, not confirmation**. A confirmation dialog
/// would still be a shell-execution feature with a speed bump in front of it,
/// and users click through speed bumps; a prompt that asks the agent to run
/// something instead lands in the agent's own permission prompt, which the user
/// already reads and answers. That gate is better than any we would build.
///
/// Restriction alone is not enough, because a prompt is typed into a TUI:
///
/// - A carriage return submits. `"do it\r!rm -rf ~"` would be *two* inputs, and
///   `!` is Claude Code's own shell escape — so an unchecked prompt string is a
///   shell case with extra steps. Control characters and escape sequences are
///   therefore rejected outright.
/// - A prompt starting `/` or `!` is refused for the same reason: a prompt that
///   wants a slash command declares `.slashCommand` and gets its command name
///   character-checked.
///
/// See `KeyMapStore.rejection(_:)` for the enforced rules and
/// `KeyMapStore.selfCheckFailures()` for the assertions that keep them enforced.
public struct PresetAction: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Text typed at the prompt.
        case prompt
        /// A slash command, stored without its leading slash.
        case slashCommand = "slash"

        public var label: String {
            switch self {
            case .prompt: "prompt"
            case .slashCommand: "slash command"
            }
        }
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }

    public static func prompt(_ text: String) -> PresetAction {
        PresetAction(kind: .prompt, text: text)
    }

    /// `slash("compact")`, no leading slash.
    public static func slash(_ command: String) -> PresetAction {
        PresetAction(kind: .slashCommand, text: command)
    }

    /// The exact bytes to send. The single place the leading slash is added, so
    /// storage and dispatch cannot disagree about whether it is already there.
    public var stdinText: String {
        switch kind {
        case .prompt: text
        case .slashCommand: "/" + text
        }
    }
}

/// A name plus an action, and nothing else. No closure: a stored preset is data,
/// so it can be written to a file, diffed, and re-read on the next launch.
public struct Preset: Codable, Sendable, Equatable {
    public var name: String
    public var action: PresetAction

    public init(name: String, action: PresetAction) {
        self.name = name
        self.action = action
    }
}

// MARK: - Store

/// Where the two custom command slots and the four pad presets are bound, and
/// the resolution rule that decides which binding a key actually has.
///
/// **Resolution is project, then global, then built-in default.** PLAN.md settled
/// this: global-only breaks for anyone with several repos, per-project-only costs
/// too much setup to survive the activation metric. So a fresh install works with
/// no configuration at all, one global edit follows the user everywhere, and a
/// repo that needs something different says so locally.
///
/// The resolution is *explainable* rather than just correct. `resolve` reports the
/// layer it came from and the layers it shadowed, because "why is this key doing
/// that" is otherwise unanswerable — and the answer is nearly always "a project
/// override you forgot about".
///
/// Storage follows `SessionRegistry`: a plain readable file in Application
/// Support, atomic writes, reusing that file's `BindingStore` protocol so the
/// self check runs entirely in memory. `UserDefaults` is not an option here for
/// the same reason it was not there — see the comment on `FileBindingStore`; a
/// defaults domain keyed by process name loses everything the first time the
/// binary runs from the `.app` bundle, which is the normal way to run it.
///
/// A value type, mutated in place, like `SessionRegistry` and `StateEngine`.
public struct KeyMapStore: Sendable {

    // MARK: Layers

    public enum Layer: String, Codable, Sendable, CaseIterable {
        case project
        case global
        case builtIn

        public var label: String {
            switch self {
            case .project: "this project"
            case .global: "your global defaults"
            case .builtIn: "the built-in default"
            }
        }

        /// Whether a user can write to it. The built-in layer is code, not config.
        public var isEditable: Bool { self != .builtIn }
    }

    /// One key's effective binding plus where it came from.
    public struct ResolvedBinding: Sendable, Equatable {
        public let target: KeyMapTarget
        public let preset: Preset
        public let layer: Layer
        /// Layers below the winner that also hold a binding for this target,
        /// nearest first. This is the part that makes a surprising key
        /// explainable: an empty list means nothing is being overridden, a
        /// non-empty one names exactly what is.
        public let shadowed: [Layer]
        /// The project this was resolved for, `nil` when there was no project
        /// context. Carried so the explanation can name the path.
        public let projectPath: String?

        /// One sentence, for the editor and for VoiceOver.
        public var explanation: String {
            let origin: String
            switch layer {
            case .project:
                let path = projectPath.map { " (\(($0 as NSString).abbreviatingWithTildeInPath))" } ?? ""
                origin = "set for this project\(path)"
            case .global:
                origin = "from your global defaults"
            case .builtIn:
                origin = "the built-in default — nothing has been configured for this key"
            }
            guard !shadowed.isEmpty else { return origin }
            return origin + ", overriding " + shadowed.map(\.label).joined(separator: " and ")
        }
    }

    // MARK: Built-in defaults

    /// The documented defaults. The four pad names are the PRD's own examples and
    /// must stay in step with `DirectionPadView.defaultPresetNames`, which the
    /// self check asserts rather than trusts.
    ///
    /// All prompts, bar one slash command, and every one of them phrased to ask
    /// for work rather than to run it — the built-ins are also the worked example
    /// a user copies when writing their own.
    public static let builtInDefaults: [KeyMapTarget: Preset] = [
        .pad(.up): Preset(
            name: "review PR",
            action: .prompt(
                "Review the pull request for this branch: walk the diff, call out anything "
                    + "risky, and list what still needs a human decision."
            )
        ),
        .pad(.right): Preset(
            name: "debug issue",
            action: .prompt(
                "Reproduce the failure I just described, find the root cause rather than the "
                    + "symptom, and tell me which other callers share it before changing anything."
            )
        ),
        .pad(.down): Preset(
            name: "explain code",
            action: .prompt(
                "Explain the code I am looking at: what it does, why it is shaped this way, "
                    + "and what breaks if it changes."
            )
        ),
        .pad(.left): Preset(
            name: "write docs",
            action: .prompt(
                "Document the change on this branch: what it does, how to use it, and the "
                    + "limits worth knowing about."
            )
        ),
        .command(.custom1): Preset(
            name: "summarise changes",
            action: .prompt("Summarise what you changed in this session and why, one line per file.")
        ),
        .command(.custom2): Preset(
            name: "compact context",
            action: .slash("compact")
        ),
    ]

    // MARK: Validation

    public static let maximumNameLength = 48
    public static let maximumActionLength = 2000

    /// `nil` when the preset is safe to store or run. Otherwise the sentence the
    /// editor shows and the import path logs.
    ///
    /// Applied on every write, not only on import: a preset typed by hand and one
    /// arriving in a file end up in the same place and are sent to the same PTY,
    /// so one gate serves both. See `PresetAction` for why each rule is here.
    public static func rejection(_ preset: Preset) -> String? {
        let name = preset.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "a preset needs a name" }
        if name.count > maximumNameLength {
            return "the name is longer than \(maximumNameLength) characters"
        }
        if let bad = controlCharacter(in: preset.name) {
            return "the name contains a control character (\(describe(bad)))"
        }
        return rejection(preset.action)
    }

    public static func rejection(_ action: PresetAction) -> String? {
        let text = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "a \(action.kind.label) needs something to send" }
        if action.text.count > maximumActionLength {
            return "the action is longer than \(maximumActionLength) characters"
        }
        // The load-bearing rule. A return submits, so one string with a newline in
        // it is two inputs, and Claude Code reads a leading `!` as a shell escape.
        if let bad = controlCharacter(in: action.text) {
            return "the action contains a control character (\(describe(bad))), which would "
                + "split it into more than one input"
        }
        switch action.kind {
        case .prompt:
            if text.hasPrefix("/") {
                return "a prompt cannot start with \"/\" — use a slash command instead, "
                    + "so the command name can be checked"
            }
            if text.hasPrefix("!") {
                return "a prompt cannot start with \"!\" — that is the agent's shell escape, "
                    + "and a preset is not allowed to run shell commands"
            }
        case .slashCommand:
            // Validate the WHOLE text, not just the part before the first space.
            // Taking a prefix silently accepted "com mand" as "com" and dropped the
            // rest, so an imported file could carry trailing content past the name
            // that validation never looked at. The field stores a command name
            // only; if arguments are ever needed they get their own checked field
            // rather than being smuggled through this one.
            if text.contains(" ") {
                return "a slash command name cannot contain a space — store the command "
                    + "name on its own, without arguments"
            }
            let allowed = text.allSatisfy { $0.isLetter || $0.isNumber || "-_:".contains($0) }
            if !allowed {
                return "\"\(text)\" is not a valid slash command name — letters, digits, "
                    + "\"-\", \"_\" and \":\" only"
            }
        }
        return nil
    }

    private static func controlCharacter(in text: String) -> Character? {
        text.first { character in
            character.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        }
    }

    private static func describe(_ character: Character) -> String {
        guard let scalar = character.unicodeScalars.first else { return "?" }
        return String(format: "U+%04X", scalar.value)
    }

    // MARK: Pure resolution

    /// The whole rule, as a function of its inputs and nothing else. Project
    /// first, then global, then the built-in default.
    ///
    /// Two things it deliberately does *not* do. It does not fall back from a
    /// project that exists but has no entry for this target straight to the
    /// built-in default — that would make one project override silently disable
    /// every global default for that repo. And it does not merge layers into one
    /// dictionary before choosing, because the discarded layers are the answer to
    /// "why is this key doing that" and merging throws them away.
    ///
    /// `nil` only when no layer, defaults included, has anything for this target.
    /// With `builtInDefaults` that cannot happen, and the self check asserts it.
    public static func resolve(
        _ target: KeyMapTarget,
        projectPath: String?,
        projects: [String: [KeyMapTarget: Preset]],
        global: [KeyMapTarget: Preset],
        defaults: [KeyMapTarget: Preset] = KeyMapStore.builtInDefaults
    ) -> ResolvedBinding? {
        let candidates: [(layer: Layer, preset: Preset?)] = [
            (.project, projectPath.flatMap { projects[$0]?[target] }),
            (.global, global[target]),
            (.builtIn, defaults[target]),
        ]
        guard let winner = candidates.firstIndex(where: { $0.preset != nil }),
              let preset = candidates[winner].preset
        else { return nil }

        return ResolvedBinding(
            target: target,
            preset: preset,
            layer: candidates[winner].layer,
            shadowed: candidates[(winner + 1)...].compactMap { $0.preset == nil ? nil : $0.layer },
            projectPath: projectPath
        )
    }

    // MARK: Instance

    private let store: any BindingStore
    private var global: [KeyMapTarget: Preset] = [:]
    private var projects: [String: [KeyMapTarget: Preset]] = [:]
    /// Anything that went wrong reading, writing or validating, newest last,
    /// capped. Non-empty means a person should look; it never means stop.
    public private(set) var warnings: [String] = []

    private static let warningLimit = 16

    public static let defaultFileStore: FileBindingStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return FileBindingStore(url: base.appendingPathComponent("VirtualCodexMicro/keymap.json"))
    }()

    /// A malformed file is a bad launch, not a crash. Every failure path here ends
    /// with the built-in defaults and a logged reason.
    ///
    /// **Rejection is per layer, never per binding.** A layer that fails to decode
    /// or fails validation is dropped whole. Half a keymap is the worst outcome
    /// available: some keys move, some do not, and nothing on screen says which,
    /// so the user cannot tell a broken file from a mistake they made.
    public init(store: any BindingStore = KeyMapStore.defaultFileStore) {
        self.store = store

        do {
            guard let data = try store.read() else { return }
            let payload = try JSONDecoder().decode(Payload.self, from: data)
            guard payload.version == Payload.currentVersion else {
                warn("keymap version \(payload.version) is not \(Payload.currentVersion); using built-in defaults")
                return
            }
            // decode returns (layer:reason:) where a nil layer means the whole
            // layer was rejected and `reason` says why. Per-layer, never
            // per-binding: half a keymap is the worst available outcome.
            let decodedGlobal = Self.decode(payload.global)
            if let layer = decodedGlobal.layer {
                global = layer
            } else {
                warn("global keymap rejected (\(decodedGlobal.reason)); using built-in defaults")
            }
            for (path, raw) in payload.projects {
                let decoded = Self.decode(raw)
                if let layer = decoded.layer {
                    projects[path] = layer
                } else {
                    warn("keymap for \(path) rejected (\(decoded.reason)); falling back to global")
                }
            }
        } catch {
            warn("keymap unreadable (\(error)); using built-in defaults")
        }
    }

    /// All or nothing. An unknown target id fails the layer rather than being
    /// skipped: the `version` field is how a future build adds a target, so an
    /// unrecognised key here means the file is not what it claims to be.
    /// `nil` means the layer is rejected whole, and the string says why.
    private static func decode(_ raw: [String: Preset]) -> (layer: [KeyMapTarget: Preset]?, reason: String) {
        var layer: [KeyMapTarget: Preset] = [:]
        for (id, preset) in raw.sorted(by: { $0.key < $1.key }) {
            guard let target = KeyMapTarget(wireID: id) else {
                return (nil, "\"\(id)\" is not a remappable key")
            }
            if let reason = rejection(preset) {
                return (nil, "\(id): \(reason)")
            }
            layer[target] = preset
        }
        return (layer, "")
    }

    // MARK: Reading

    public func resolved(_ target: KeyMapTarget, projectPath: String? = nil) -> ResolvedBinding? {
        Self.resolve(target, projectPath: projectPath, projects: projects, global: global)
    }

    /// Every remappable key in a stable order — custom keys, then the pad
    /// clockwise from the top. The editor renders this directly.
    public func allResolved(projectPath: String? = nil) -> [ResolvedBinding] {
        KeyMapTarget.allCases.compactMap { resolved($0, projectPath: projectPath) }
    }

    /// What one layer holds by itself, with no resolution applied. The editor
    /// needs this to answer "is there anything here to reset".
    public func layerBindings(_ layer: Layer, projectPath: String? = nil) -> [KeyMapTarget: Preset] {
        switch layer {
        case .project: projectPath.flatMap { projects[$0] } ?? [:]
        case .global: global
        case .builtIn: Self.builtInDefaults
        }
    }

    // MARK: Writing

    /// Binds a preset in one layer. Returns `nil` on success, otherwise the
    /// reason it was refused — the same string the editor shows.
    ///
    /// Validated on the way in rather than on the way out, so an invalid preset
    /// never reaches the file and cannot come back as a rejected layer on the
    /// next launch.
    @discardableResult
    public mutating func set(
        _ preset: Preset, for target: KeyMapTarget, layer: Layer, projectPath: String? = nil
    ) -> String? {
        guard layer.isEditable else {
            return "the built-in defaults cannot be edited — set this in your global defaults instead"
        }
        if let reason = Self.rejection(preset) { return reason }

        switch layer {
        case .global:
            global[target] = preset
        case .project:
            guard let path = projectPath, !path.isEmpty else {
                return "no project is open, so there is nowhere to store a project override"
            }
            projects[path, default: [:]][target] = preset
        case .builtIn:
            return "the built-in defaults cannot be edited"
        }
        persist()
        return nil
    }

    /// Drops one binding from one layer, so the key falls back to whatever is
    /// underneath. Not the same as binding the underlying value explicitly: reset
    /// keeps tracking the layer below, a copy freezes it.
    public mutating func reset(_ target: KeyMapTarget, layer: Layer, projectPath: String? = nil) {
        switch layer {
        case .global:
            global[target] = nil
        case .project:
            guard let path = projectPath else { return }
            projects[path]?[target] = nil
            if projects[path]?.isEmpty == true { projects[path] = nil }
        case .builtIn:
            return
        }
        persist()
    }

    public mutating func resetLayer(_ layer: Layer, projectPath: String? = nil) {
        switch layer {
        case .global:
            global = [:]
        case .project:
            guard let path = projectPath else { return }
            projects[path] = nil
        case .builtIn:
            return
        }
        persist()
    }

    // MARK: Import

    public struct ImportResult: Sendable, Equatable {
        public let accepted: Int
        /// Empty when the whole file was applied. Otherwise nothing was.
        public let rejected: [String]

        public var isAccepted: Bool { rejected.isEmpty }
    }

    /// Reads one layer's worth of presets from a file the user supplied — the
    /// untrusted path, and the reason `PresetAction` has no shell case.
    ///
    /// All or nothing again, for the reason `init` gives: a partly applied import
    /// leaves the user unable to tell which keys moved. Anything that fails
    /// `rejection(_:)` fails the import, so an action carrying a carriage return
    /// or a shell escape is refused rather than quietly stored.
    @discardableResult
    public mutating func importPresets(
        _ data: Data, into layer: Layer, projectPath: String? = nil
    ) -> ImportResult {
        guard layer.isEditable else {
            return ImportResult(accepted: 0, rejected: ["the built-in defaults cannot be replaced"])
        }
        let path = projectPath.flatMap { $0.isEmpty ? nil : $0 }
        if layer == .project, path == nil {
            return ImportResult(accepted: 0, rejected: ["no project is open to import into"])
        }

        let raw: [String: Preset]
        do {
            raw = try JSONDecoder().decode([String: Preset].self, from: data)
        } catch {
            let reason = "the file is not a keymap layer (\(error))"
            warn("import refused: \(reason)")
            return ImportResult(accepted: 0, rejected: [reason])
        }

        var reasons: [String] = []
        var incoming: [KeyMapTarget: Preset] = [:]
        for (id, preset) in raw.sorted(by: { $0.key < $1.key }) {
            guard let target = KeyMapTarget(wireID: id) else {
                reasons.append("\"\(id)\" is not a remappable key")
                continue
            }
            if let reason = Self.rejection(preset) {
                reasons.append("\(id): \(reason)")
                continue
            }
            incoming[target] = preset
        }
        if incoming.isEmpty, reasons.isEmpty {
            reasons.append("the file contains no presets")
        }
        guard reasons.isEmpty else {
            for reason in reasons { warn("import refused: \(reason)") }
            return ImportResult(accepted: 0, rejected: reasons)
        }

        for (target, preset) in incoming {
            switch layer {
            case .global: global[target] = preset
            case .project: if let path { projects[path, default: [:]][target] = preset }
            case .builtIn: break
            }
        }
        persist()
        return ImportResult(accepted: incoming.count, rejected: [])
    }

    /// One layer as an importable file. Same shape `importPresets` reads, so
    /// export then import is a round trip and two machines' keymaps diff line by
    /// line.
    public func exportLayer(_ layer: Layer, projectPath: String? = nil) -> Data {
        let raw = Dictionary(
            uniqueKeysWithValues: layerBindings(layer, projectPath: projectPath)
                .map { ($0.key.wireID, $0.value) }
        )
        return (try? Self.encoder.encode(raw)) ?? Data()
    }

    // MARK: Store plumbing

    /// Sorted keys and pretty printing because the task calls for a file that is
    /// importable and diffable: one field per line, stable order, so a diff shows
    /// the binding that changed rather than the whole file.
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private struct Payload: Codable {
        static let currentVersion = 1
        var version: Int
        /// Keyed by `KeyMapTarget.wireID`. A string-keyed object rather than the
        /// Swift enum, so the format survives a case rename.
        var global: [String: Preset]
        /// Keyed by absolute project path.
        var projects: [String: [String: Preset]]
    }

    private mutating func persist() {
        func wire(_ layer: [KeyMapTarget: Preset]) -> [String: Preset] {
            Dictionary(uniqueKeysWithValues: layer.map { ($0.key.wireID, $0.value) })
        }
        let payload = Payload(
            version: Payload.currentVersion,
            global: wire(global),
            projects: projects.mapValues(wire)
        )
        do {
            let data = try Self.encoder.encode(payload)
            try store.write(data)
        } catch {
            warn("could not persist the keymap (\(error)); the change is in memory only")
        }
    }

    private mutating func warn(_ message: String) {
        log.error("\(message, privacy: .public)")
        warnings.append(message)
        if warnings.count > Self.warningLimit { warnings.removeFirst() }
    }
}

// MARK: - Self check

public extension KeyMapStore {
    /// Human-readable failures, empty when healthy. Wire into `SelfCheck` with:
    ///
    ///     failures += KeyMapStore.selfCheckFailures().map { "keymap: \($0)" }
    ///     failures += KeyMapEditorView.selfCheckFailures().map { "keymapui: \($0)" }
    ///
    /// Injected store throughout. Nothing here touches a disk or a defaults
    /// domain, so it cannot flake and cannot be polluted by a previous run.
    static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let repo = "/Users/x/work/ledger"
        let other = "/Users/x/work/docs"
        let target = KeyMapTarget.pad(.up)
        let projectPreset = Preset(name: "project review", action: .prompt("review this repo's PR"))
        let globalPreset = Preset(name: "global review", action: .prompt("review the PR"))

        // 1. Every remappable target has a built-in default, or a key resolves to
        //    nothing and the editor silently drops a row.
        for target in KeyMapTarget.allCases {
            check("\(target.wireID) has no built-in default", builtInDefaults[target] != nil)
            check("\(target.wireID) has no label", !target.label.isEmpty)
            check("\(target.wireID) does not survive its wire id", KeyMapTarget(wireID: target.wireID) == target)
        }
        check(
            "built-in defaults cover keys that are not remappable",
            Set(builtInDefaults.keys) == Set(KeyMapTarget.allCases)
        )
        for (target, preset) in builtInDefaults {
            if let reason = rejection(preset) {
                failures.append("built-in default \(target.wireID) fails its own validation: \(reason)")
            }
        }
        // The pad's four names are the PRD's, and `DirectionPadView` publishes them
        // too. Two copies of the same list is exactly how they drift.
        for (direction, name) in DirectionPadView.defaultPresetNames {
            check(
                "pad \(direction.rawValue) default is \"\(builtInDefaults[.pad(direction)]?.name ?? "nil")\", not \"\(name)\"",
                builtInDefaults[.pad(direction)]?.name == name
            )
        }
        // Fixed keys must not be addressable from a file.
        for id in ["command.accept", "command.reject", "command.newSession", "command.pushToTalk",
                   "pad.center", "pad", "", "nonsense", "pad.up.extra"] {
            check("\"\(id)\" was accepted as a remappable target", KeyMapTarget(wireID: id) == nil)
        }

        // 2. Each layer wins in turn, and says which one it was.
        let bothLayers = resolve(
            target, projectPath: repo,
            projects: [repo: [target: projectPreset]], global: [target: globalPreset]
        )
        check("a project override did not win", bothLayers?.preset == projectPreset)
        check("a project win was not attributed to the project layer", bothLayers?.layer == .project)
        check(
            "a project win did not report what it shadowed",
            bothLayers?.shadowed == [.global, .builtIn]
        )
        check(
            "a project win does not explain itself",
            bothLayers?.explanation.contains("this project") == true
                && bothLayers?.explanation.contains("overriding") == true
        )

        // The case the task singles out: a project that exists in the file but has
        // no entry for THIS key falls back to global, not to the built-in default.
        let projectWithoutThisKey = resolve(
            target, projectPath: repo,
            projects: [repo: [.pad(.down): projectPreset]], global: [target: globalPreset]
        )
        check("a project with no override for this key did not fall back", projectWithoutThisKey?.preset == globalPreset)
        check(
            "a project with no override for this key skipped past global to the built-in default",
            projectWithoutThisKey?.layer == .global
        )
        check(
            "a global win claimed to shadow global",
            projectWithoutThisKey?.shadowed == [.builtIn]
        )
        // And a project not mentioned in the file at all behaves the same way.
        let unknownProject = resolve(
            target, projectPath: other,
            projects: [repo: [target: projectPreset]], global: [target: globalPreset]
        )
        check("an unconfigured project picked up another project's override", unknownProject?.preset == globalPreset)
        check("an unconfigured project did not resolve from global", unknownProject?.layer == .global)
        // No project context at all: global still applies.
        let noProject = resolve(
            target, projectPath: nil,
            projects: [repo: [target: projectPreset]], global: [target: globalPreset]
        )
        check("with no project open a project override leaked in", noProject?.layer == .global)

        // Built-in default wins only when nothing else has anything.
        let bare = resolve(target, projectPath: repo, projects: [:], global: [:])
        check("an unconfigured key did not resolve to its built-in default", bare?.preset == builtInDefaults[target])
        check("an unconfigured key was not attributed to the built-in layer", bare?.layer == .builtIn)
        check("the built-in layer claims to shadow something", bare?.shadowed.isEmpty == true)
        check(
            "the built-in layer does not say nothing is configured",
            bare?.explanation.contains("nothing has been configured") == true
        )
        // A project override with no global underneath still reports honestly.
        let projectOnly = resolve(
            target, projectPath: repo, projects: [repo: [target: projectPreset]], global: [:]
        )
        check("a project override with no global beneath it mis-reported", projectOnly?.layer == .project)
        check("a project override invented a global layer to shadow", projectOnly?.shadowed == [.builtIn])
        // Nothing anywhere, defaults included: nil rather than a crash.
        check(
            "a target with no binding in any layer did not resolve to nil",
            resolve(target, projectPath: nil, projects: [:], global: [:], defaults: [:]) == nil
        )

        // 3. Round trip: every binding in every layer survives a reload.
        let store = MemoryBindingStore()
        var writing = KeyMapStore(store: store)
        for (index, target) in KeyMapTarget.allCases.enumerated() {
            let reason = writing.set(
                Preset(name: "global \(index)", action: .prompt("global prompt \(index)")),
                for: target, layer: .global
            )
            check("setting a global binding was refused: \(reason ?? "")", reason == nil)
            let projectReason = writing.set(
                Preset(name: "project \(index)", action: .slash("cmd-\(index)")),
                for: target, layer: .project, projectPath: repo
            )
            check("setting a project binding was refused: \(projectReason ?? "")", projectReason == nil)
        }
        // A second project, so the file is not trivially one-project shaped.
        writing.set(
            Preset(name: "docs only", action: .prompt("write the docs")),
            for: .pad(.left), layer: .project, projectPath: other
        )
        let reloaded = KeyMapStore(store: store)
        check("a round trip logged a warning: \(reloaded.warnings.joined(separator: "; "))", reloaded.warnings.isEmpty)
        for target in KeyMapTarget.allCases {
            check(
                "\(target.wireID) lost its global binding in the round trip",
                reloaded.layerBindings(.global)[target] == writing.layerBindings(.global)[target]
            )
            check(
                "\(target.wireID) lost its project binding in the round trip",
                reloaded.resolved(target, projectPath: repo)?.preset
                    == writing.resolved(target, projectPath: repo)?.preset
            )
            check(
                "\(target.wireID) lost its layer attribution in the round trip",
                reloaded.resolved(target, projectPath: repo)?.layer == .project
            )
        }
        check(
            "the second project did not survive the round trip",
            reloaded.resolved(.pad(.left), projectPath: other)?.preset.name == "docs only"
        )
        check(
            "the second project inherited the first project's overrides",
            reloaded.resolved(.pad(.up), projectPath: other)?.layer == .global
        )
        check(
            "an exported layer is not re-importable",
            (try? JSONDecoder().decode([String: Preset].self, from: reloaded.exportLayer(.global)))?.count
                == KeyMapTarget.allCases.count
        )

        // 4. Reset drops one binding, resetLayer drops the lot, and both fall back
        //    rather than clearing the key.
        var resetting = writing
        resetting.reset(.pad(.up), layer: .project, projectPath: repo)
        check("resetting a project binding did not fall back to global", resetting.resolved(.pad(.up), projectPath: repo)?.layer == .global)
        check("resetting one project binding took the others with it", resetting.resolved(.pad(.down), projectPath: repo)?.layer == .project)
        resetting.resetLayer(.project, projectPath: repo)
        for target in KeyMapTarget.allCases {
            check("\(target.wireID) survived a project layer reset", resetting.resolved(target, projectPath: repo)?.layer == .global)
        }
        check("resetting one project's layer cleared another's", resetting.resolved(.pad(.left), projectPath: other)?.layer == .project)
        resetting.resetLayer(.global)
        for target in KeyMapTarget.allCases {
            check("\(target.wireID) did not return to its built-in default", resetting.resolved(target)?.layer == .builtIn)
            check("\(target.wireID) lost its binding entirely", resetting.resolved(target) != nil)
        }
        // The built-in layer is code. It refuses writes and ignores resets.
        var immutable = KeyMapStore(store: MemoryBindingStore())
        check(
            "the built-in layer accepted a write",
            immutable.set(globalPreset, for: target, layer: .builtIn) != nil
        )
        immutable.resetLayer(.builtIn)
        check("the built-in layer was cleared", immutable.resolved(target)?.preset == builtInDefaults[target])
        // A project write with no project open is refused, not silently dropped in
        // the global layer.
        check(
            "a project write with no project open was accepted",
            immutable.set(globalPreset, for: target, layer: .project, projectPath: nil) != nil
        )
        check("a refused project write leaked into global", immutable.layerBindings(.global).isEmpty)

        // 5. Corrupt, partial and unreadable stores yield exactly the defaults,
        //    with a reason, without throwing.
        let invalidAction = #"{"version":1,"global":{"pad.up":{"name":"x","action":{"kind":"prompt","text":"do it\r!rm -rf ~"}}},"projects":{}}"#
        let unknownKey = #"{"version":1,"global":{"command.accept":{"name":"x","action":{"kind":"prompt","text":"go"}}},"projects":{}}"#
        let unknownKind = #"{"version":1,"global":{"pad.up":{"name":"x","action":{"kind":"shell","text":"rm -rf ~"}}},"projects":{}}"#
        for (label, badStore) in [
            ("garbage", MemoryBindingStore(data: Data("not json at all".utf8))),
            ("truncated", MemoryBindingStore(data: Data(#"{"version":1,"global":{"pad.up""#.utf8))),
            ("wrong version", MemoryBindingStore(data: Data(#"{"version":99,"global":{},"projects":{}}"#.utf8))),
            ("empty file", MemoryBindingStore(data: Data())),
            ("unreadable", MemoryBindingStore(readError: MemoryBindingStore.Failure.unreadable)),
            ("unsafe action", MemoryBindingStore(data: Data(invalidAction.utf8))),
            ("unknown key", MemoryBindingStore(data: Data(unknownKey.utf8))),
            ("unknown action kind", MemoryBindingStore(data: Data(unknownKind.utf8))),
        ] {
            let broken = KeyMapStore(store: badStore)
            check("\(label) store logged no reason", !broken.warnings.isEmpty)
            let resolved = broken.allResolved(projectPath: repo)
            check("\(label) store did not resolve every key", resolved.count == KeyMapTarget.allCases.count)
            for binding in resolved {
                check(
                    "\(label) store half-applied \(binding.target.wireID) from \(binding.layer.rawValue)",
                    binding.layer == .builtIn
                )
                check(
                    "\(label) store changed the default for \(binding.target.wireID)",
                    binding.preset == builtInDefaults[binding.target]
                )
            }
        }
        // One bad project layer must not take the global layer or a good project
        // with it — layer granularity is the point of rejecting per layer.
        let mixed = #"""
        {"version":1,
         "global":{"pad.up":{"name":"global up","action":{"kind":"prompt","text":"good"}}},
         "projects":{
           "/bad":{"pad.up":{"name":"bad","action":{"kind":"prompt","text":"one\ntwo"}}},
           "/good":{"pad.down":{"name":"good down","action":{"kind":"prompt","text":"fine"}}}}}
        """#
        let partial = KeyMapStore(store: MemoryBindingStore(data: Data(mixed.utf8)))
        check("a bad project layer was accepted", !partial.warnings.isEmpty)
        check("a bad project layer took the global layer with it", partial.resolved(.pad(.up))?.preset.name == "global up")
        check("a bad project fell past global to the built-in default", partial.resolved(.pad(.up), projectPath: "/bad")?.layer == .global)
        check("a good project layer was dropped alongside a bad one", partial.resolved(.pad(.down), projectPath: "/good")?.layer == .project)
        // A first launch is not a corrupt store and must not warn.
        check("a first launch logged a warning", KeyMapStore(store: MemoryBindingStore()).warnings.isEmpty)
        // A corrupt store still accepts writes and repairs itself.
        let repairing = MemoryBindingStore(data: Data("junk".utf8))
        var repaired = KeyMapStore(store: repairing)
        repaired.set(globalPreset, for: target, layer: .global)
        check(
            "a corrupt keymap was not overwritten by the next edit",
            KeyMapStore(store: repairing).resolved(target)?.preset == globalPreset
        )

        // 6. The safety rule, enforced rather than documented. Every one of these
        //    is a way to turn "text typed at a prompt" into something else.
        let unsafe: [(String, PresetAction)] = [
            ("carriage return", .prompt("do it\rrm -rf ~")),
            ("newline", .prompt("do it\nrm -rf ~")),
            ("escape sequence", .prompt("do it\u{1b}[2J")),
            ("shell escape prefix", .prompt("!rm -rf ~")),
            ("slash command disguised as a prompt", .prompt("/permissions allow Bash")),
            ("empty prompt", .prompt("   ")),
            ("slash command with a space in its name", .slash("hack me")),
            ("slash command with a shell character", .slash("compact;rm")),
            ("slash command with a newline", .slash("compact\rmalicious")),
            ("overlong action", .prompt(String(repeating: "a", count: maximumActionLength + 1))),
        ]
        for (label, action) in unsafe {
            let preset = Preset(name: "import", action: action)
            check("an action with a \(label) passed validation", rejection(preset) != nil)

            // The whole point: it must be refused on the way in from a file too.
            var importing = KeyMapStore(store: MemoryBindingStore())
            let wire = ["pad.up": preset]
            let data = (try? encoder.encode(wire)) ?? Data()
            let result = importing.importPresets(data, into: .global)
            check("an imported action with a \(label) was accepted", !result.isAccepted)
            check("a refused import still counted bindings (\(label))", result.accepted == 0)
            check("a refused import gave no reason (\(label))", !result.rejected.isEmpty)
            check(
                "a refused import changed the keymap (\(label))",
                importing.resolved(.pad(.up))?.layer == .builtIn
            )
            check("a refused import logged nothing (\(label))", !importing.warnings.isEmpty)
        }
        // There is no shell action to reject, because there is no shell action.
        check(
            "PresetAction gained a kind beyond prompt and slash command",
            Set(PresetAction.Kind.allCases) == [.prompt, .slashCommand]
        )
        check(
            "a slash command lost its leading slash on the way to stdin",
            PresetAction.slash("compact").stdinText == "/compact"
        )
        check(
            "a prompt gained a leading slash on the way to stdin",
            PresetAction.prompt("go").stdinText == "go"
        )

        // A safe import is accepted, or the check above passes by refusing
        // everything.
        var accepting = KeyMapStore(store: MemoryBindingStore())
        let safe = ["pad.up": Preset(name: "imported review", action: .prompt("review the PR")),
                    "command.custom1": Preset(name: "imported note", action: .slash("compact"))]
        let good = accepting.importPresets((try? encoder.encode(safe)) ?? Data(), into: .global)
        check("a safe import was refused: \(good.rejected.joined(separator: "; "))", good.isAccepted)
        check("a safe import applied the wrong number of bindings", good.accepted == 2)
        check("a safe import did not take effect", accepting.resolved(.pad(.up))?.preset.name == "imported review")
        check("a safe import touched a key it did not mention", accepting.resolved(.pad(.down))?.layer == .builtIn)
        check("a safe import logged a warning", accepting.warnings.isEmpty)
        // An empty file is not a valid import: it reads as "reset everything".
        check(
            "an empty import was accepted",
            !accepting.importPresets(Data("{}".utf8), into: .global).isAccepted
        )
        // Importing into a project needs a project.
        check(
            "a project import with no project open was accepted",
            !accepting.importPresets((try? encoder.encode(safe)) ?? Data(), into: .project).isAccepted
        )

        return failures
    }
}
