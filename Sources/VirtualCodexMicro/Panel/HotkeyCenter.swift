import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts: one to summon or hide the panel, one to
/// toggle pin. Both fire while another application is frontmost.
///
/// **Carbon, on purpose.** This uses `RegisterEventHotKey` /
/// `InstallEventHandler` rather than `NSEvent.addGlobalMonitorForEvents`, and it
/// should stay that way. A global NSEvent monitor sees keystrokes from other
/// applications only once the user has granted Accessibility in System
/// Settings — asking for the permission that also allows reading every keystroke
/// in every window, just so a panel can appear, is a bad first run and a fair
/// reason to distrust the app. Carbon hotkey registration needs no TCC grant at
/// all. What it does need is bundle identity, which is why `Scripts/bundle.sh`
/// exists (see PLAN.md, "Build environment"). If you are here to "modernise"
/// this to the NSEvent route: that trade is Accessibility-for-nothing.
///
/// Isolation: all mutable state is `@MainActor`. Carbon hands events to a C
/// function pointer that cannot capture context, so the callback finds its Swift
/// closure through `byID`, a registry keyed by the `EventHotKeyID` we allocated.
/// The callback reaches that registry with `MainActor.assumeIsolated` — sound,
/// not a shortcut: the handler is installed on `GetApplicationEventTarget()`,
/// whose events are dispatched by the main thread's run loop, so the callback
/// only ever runs on the main thread. That is what makes this safe without
/// `@unchecked Sendable` anywhere.
@MainActor
public final class HotkeyCenter {

    // MARK: - Bindings

    public enum Action: String, CaseIterable, Sendable {
        /// Show the panel, or hide it if it is already showing.
        case summon
        /// Toggle pinned (stays visible when focus moves elsewhere).
        case pin

        /// Defaults: **Control-Option-Command-V** summons, **Control-Option-Command-P**
        /// pins. Chosen for the emptiest region of the macOS shortcut space —
        /// all three of control, option and command together with a *letter*.
        /// macOS itself claims that modifier trio only with digits and
        /// punctuation (Control-Option-Command-8 inverts colours,
        /// Control-Option-Command-comma/period adjust contrast), and applications
        /// almost never reach past two modifiers for their own menu items. The
        /// obvious mnemonic combinations are all taken and were rejected:
        /// anything with Space collides with Spotlight (Command-Space), the
        /// emoji picker (Control-Command-Space), Finder search
        /// (Option-Command-Space), input-source switching and every launcher
        /// people install; single- and double-modifier letters collide with
        /// ordinary menu shortcuts in whichever app is frontmost. V and P are
        /// mnemonic (Virtual, Pin) and share a prefix, so one is learnable from
        /// the other. Both are overridable — see `bind(_:to:handler:)`.
        public var defaultBinding: Binding {
            switch self {
            case .summon: Binding(keyCode: kVK_ANSI_V, modifiers: [.control, .option, .command])
            case .pin: Binding(keyCode: kVK_ANSI_P, modifiers: [.control, .option, .command])
            }
        }
    }

    /// A virtual key code (the `kVK_*` constants) plus Cocoa modifier flags.
    public struct Binding: Equatable, Sendable, CustomStringConvertible {
        public let keyCode: UInt32
        public let modifiers: NSEvent.ModifierFlags

        public init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
            self.keyCode = UInt32(keyCode)
            self.modifiers = modifiers
        }

        /// Carbon modifier bits for this binding.
        public var carbonModifiers: UInt32 { HotkeyCenter.carbonModifiers(from: modifiers) }

        public static func == (lhs: Binding, rhs: Binding) -> Bool {
            lhs.keyCode == rhs.keyCode && lhs.carbonModifiers == rhs.carbonModifiers
        }

        /// Glyphs plus the raw key code — enough to identify a binding in an
        /// error message without carrying a key-code-to-label table around.
        public var description: String {
            var text = ""
            if modifiers.contains(.control) { text += "⌃" }
            if modifiers.contains(.option) { text += "⌥" }
            if modifiers.contains(.shift) { text += "⇧" }
            if modifiers.contains(.command) { text += "⌘" }
            return text + "key\(keyCode)"
        }
    }

    // MARK: - Errors

    public enum HotkeyError: Error, CustomStringConvertible {
        /// The combination is already registered — by us, or by another process
        /// that got there first.
        case alreadyTaken(Binding)
        /// Carbon refused the registration for some other reason.
        case registrationFailed(Binding, OSStatus)
        /// Installing the shared Carbon event handler failed; no hotkey can work.
        case handlerInstallFailed(OSStatus)
        /// `rebind` needs an existing handler to carry over.
        case notBound(Action)
        /// A hotkey with no modifiers would swallow that key everywhere, in every
        /// application. Refused rather than registered.
        case noModifiers(Binding)

        public var description: String {
            switch self {
            case .alreadyTaken(let binding):
                "hotkey \(binding) is already taken"
            case .registrationFailed(let binding, let status):
                "hotkey \(binding) could not be registered (OSStatus \(status))"
            case .handlerInstallFailed(let status):
                "Carbon hotkey event handler could not be installed (OSStatus \(status))"
            case .notBound(let action):
                "\(action.rawValue) has no binding to move"
            case .noModifiers(let binding):
                "hotkey \(binding) has no modifiers, which would capture that key system-wide"
            }
        }
    }

    // MARK: - State

    public static let shared = HotkeyCenter()

    /// Monotonic and never reused. An ID retired by `unbind` is not handed out
    /// again, so a Carbon event still in flight for a torn-down hotkey routes to
    /// nothing instead of to whatever was registered next.
    struct IDAllocator {
        private var last: UInt32 = 0

        mutating func next() -> UInt32 {
            last += 1
            return last
        }
    }

    private struct Registration {
        let id: UInt32
        let action: Action
        let binding: Binding
        let ref: EventHotKeyRef
        var handler: @MainActor () -> Void
    }

    /// Four-char code 'vcm1', the signature on every ID we allocate.
    private static let signature = OSType(0x7663_6D31)

    private var ids = IDAllocator()
    /// Keyed by hotkey ID because that is all the C callback gets back.
    private var byID: [UInt32: Registration] = [:]
    private var eventHandler: EventHandlerRef?

    private init() {}

    // MARK: - Public API

    /// Registers `binding` for `action`, replacing any previous binding for it.
    ///
    /// The new combination is registered *before* the old one is released, so a
    /// rejected change leaves the previous shortcut working rather than leaving
    /// the action bound to nothing.
    ///
    /// Throws on any refusal — a taken combination is never swallowed into a
    /// shortcut that looks bound and never fires. One limit worth knowing, and it
    /// is Carbon's, not ours: a combination already claimed by *another* process
    /// or by a system service usually still registers with `noErr`, and the other
    /// owner simply wins the keystroke. `eventHotKeyExistsErr` is reliable for
    /// duplicates within this application. So this API reports every failure the
    /// OS reports, and cannot report the ones it does not — which is the other
    /// half of why the defaults avoid contested combinations, and why a future
    /// recorder UI should confirm a new binding by having the user press it once.
    public func bind(_ action: Action, to binding: Binding, handler: @escaping @MainActor () -> Void) throws {
        guard binding.carbonModifiers != 0 else { throw HotkeyError.noModifiers(binding) }
        try installHandlerIfNeeded()

        // Same combination: swap the closure. Re-registering an identical
        // combination would fail with eventHotKeyExistsErr against ourselves.
        if let existing = registration(for: action), existing.binding == binding {
            byID[existing.id]?.handler = handler
            return
        }

        let id = ids.next()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.carbonModifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            if status == OSStatus(eventHotKeyExistsErr) {
                throw HotkeyError.alreadyTaken(binding)
            }
            throw HotkeyError.registrationFailed(binding, status)
        }

        if let previous = registration(for: action) {
            _ = UnregisterEventHotKey(previous.ref)
            byID[previous.id] = nil
        }
        byID[id] = Registration(id: id, action: action, binding: binding, ref: ref, handler: handler)
    }

    /// Moves `action` to a different combination, keeping its handler. For the
    /// user-configurable binding a preferences pane would eventually offer.
    public func rebind(_ action: Action, to binding: Binding) throws {
        guard let existing = registration(for: action) else { throw HotkeyError.notBound(action) }
        try bind(action, to: binding, handler: existing.handler)
    }

    public func unbind(_ action: Action) {
        guard let existing = registration(for: action) else { return }
        _ = UnregisterEventHotKey(existing.ref)
        byID[existing.id] = nil
    }

    public func unbindAll() {
        for action in Action.allCases { unbind(action) }
    }

    public func binding(for action: Action) -> Binding? { registration(for: action)?.binding }

    /// Translates Cocoa modifier flags into Carbon modifier bits, OR-ing every
    /// modifier present. Pure, so it is checkable without touching Carbon
    /// registration. Caps Lock, Fn and the numeric-keypad flag are deliberately
    /// ignored: none of them is a usable hotkey modifier, and passing them
    /// through as stray bits would produce a hotkey that never matches.
    public nonisolated static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    // MARK: - Internals

    /// Linear over `byID`, which holds one entry per `Action`. Not worth a second
    /// index at this size.
    private func registration(for action: Action) -> Registration? {
        byID.values.first { $0.action == action }
    }

    private func installHandlerIfNeeded() throws {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetApplicationEventTarget(), vcmHotkeyEventHandler, 1, &spec, nil, &ref)
        guard status == noErr, let ref else { throw HotkeyError.handlerInstallFailed(status) }
        eventHandler = ref
    }

    /// Returns false when nothing is registered for `id`, so the callback can
    /// tell Carbon the event was not handled.
    fileprivate func dispatch(id: UInt32) -> Bool {
        guard let registration = byID[id] else { return false }
        registration.handler()
        return true
    }

    // MARK: - Invariants

    /// Empty means healthy. Wired into `SelfCheck` by the caller.
    ///
    /// Registration itself is not exercised here: it needs bundle identity and a
    /// running event target, and a self-check that grabs system-wide shortcuts
    /// as a side effect is worse than no self-check. What is covered is the part
    /// that can silently rot — the modifier translation and ID allocation.
    public nonisolated static func selfCheckFailures() -> [String] {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // Each modifier alone maps to its own Carbon bit, and to nothing else.
        check("command maps to cmdKey", carbonModifiers(from: .command) == UInt32(cmdKey))
        check("option maps to optionKey", carbonModifiers(from: .option) == UInt32(optionKey))
        check("shift maps to shiftKey", carbonModifiers(from: .shift) == UInt32(shiftKey))
        check("control maps to controlKey", carbonModifiers(from: .control) == UInt32(controlKey))

        // Combinations OR together; a swapped pair of bits would still pass a
        // single-modifier check, so pairs and the full set are checked too.
        check(
            "command+shift ORs together",
            carbonModifiers(from: [.command, .shift]) == UInt32(cmdKey) | UInt32(shiftKey)
        )
        check(
            "control+option ORs together",
            carbonModifiers(from: [.control, .option]) == UInt32(controlKey) | UInt32(optionKey)
        )
        check(
            "control+option+command ORs together",
            carbonModifiers(from: [.control, .option, .command])
                == UInt32(controlKey) | UInt32(optionKey) | UInt32(cmdKey)
        )
        check(
            "all four modifiers OR together",
            carbonModifiers(from: [.command, .option, .shift, .control])
                == UInt32(cmdKey) | UInt32(optionKey) | UInt32(shiftKey) | UInt32(controlKey)
        )

        // Empty and ignorable flags produce zero, which `bind` treats as "refuse".
        check("empty flags are zero", carbonModifiers(from: []) == 0)
        check("capsLock alone is zero", carbonModifiers(from: .capsLock) == 0)
        check("function alone is zero", carbonModifiers(from: .function) == 0)
        check(
            "ignorable flags add no bits",
            carbonModifiers(from: [.command, .capsLock, .function, .numericPad]) == UInt32(cmdKey)
        )

        // ID allocation: two live registrations must never share an ID, and an
        // ID must not be reissued after its registration is torn down. Both
        // follow from strict monotonicity, so that is what is asserted.
        var allocator = IDAllocator()
        var seen = Set<UInt32>()
        var previous: UInt32 = 0
        for _ in 0 ..< 1000 {
            let id = allocator.next()
            if !seen.insert(id).inserted { failures.append("hotkey id \(id) issued twice") }
            if id <= previous { failures.append("hotkey id \(id) did not increase past \(previous)") }
            previous = id
        }

        // Defaults must be registrable and distinguishable from each other.
        for action in Action.allCases {
            check("\(action.rawValue) default has modifiers", action.defaultBinding.carbonModifiers != 0)
        }
        check("default bindings differ", Action.summon.defaultBinding != Action.pin.defaultBinding)

        return failures
    }
}

/// Carbon's callback is a bare C function pointer: no context capture, so it
/// pulls the `EventHotKeyID` out of the event and lets `HotkeyCenter` look up
/// the matching closure. See the isolation note on `HotkeyCenter` for why
/// `assumeIsolated` is correct here.
private func vcmHotkeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr else { return status }

    return MainActor.assumeIsolated {
        HotkeyCenter.shared.dispatch(id: id.id) ? noErr : OSStatus(eventNotHandledErr)
    }
}
