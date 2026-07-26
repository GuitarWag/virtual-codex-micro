import AppKit
import SwiftUI

/// The guaranteed way in, and the only route to the three configuration surfaces.
///
/// This app is `LSUIElement`: no Dock icon, no window in the app switcher, nothing
/// in the menu bar. That left exactly one way to reach the panel — the
/// Ctrl-Opt-Cmd-V Carbon hotkey — and that is the one link no check can exercise,
/// because it needs a real keypress. It failed live: a saved frame put the panel on
/// a second display and the running app had to be found with `pgrep`. A status item
/// is always on screen, costs nothing, and does not depend on a registration that
/// might have lost a conflict to something else on the system.
///
/// It also carries onboarding, the keymap editor and the activity log, all three of
/// which were built, checked, and referenced from nowhere. Hook installation in
/// particular had no consent path in the product at all before this — it required
/// `VCM_HOOKAPPLY=install` from a terminal, which is not a product.
///
/// Deliberately **not** part of `FocusOrder`. That models the panel's own 18
/// keyboard stops; the menu bar is outside the panel and the system already owns
/// its traversal (Ctrl-F8). Adding it would make the model describe a stop no view
/// implements, which is the exact bug `FocusOrder` was written to stop.
@MainActor
final class MenuBarItem: NSObject, NSMenuDelegate, NSWindowDelegate {

    // MARK: - Pure logic

    /// Whether first launch should open onboarding by itself.
    ///
    /// Two conditions, and both matter. Hooks absent, because with them installed
    /// there is nothing to ask for and an unprompted window is an interruption. Not
    /// offered before, because a user who read the screen and chose to continue
    /// without hooks has answered — re-asking every launch is nagging, and the menu
    /// item is always there for when they change their mind.
    ///
    /// "Absent" includes "could not tell": a settings file we cannot parse means
    /// hooks are not installed as far as this app is concerned, and onboarding is
    /// the surface that explains why rather than failing silently.
    nonisolated static func shouldPresentOnboarding(
        hooksInstalled: Bool, alreadyOffered: Bool
    ) -> Bool {
        !hooksInstalled && !alreadyOffered
    }

    /// The toggle item names the action, not the state — a menu item reading
    /// "Panel visible" leaves the user guessing what clicking it does.
    nonisolated static func toggleTitle(isVisible: Bool) -> String {
        isVisible ? "Hide Panel" : "Show Panel"
    }

    // MARK: - State

    private static let offeredKey = "VCM.onboarding.offered"

    private let panel: PanelController
    private let coordinator: PanelCoordinator
    private let defaults: UserDefaults
    private let item: NSStatusItem
    private let toggleItem = NSMenuItem()
    private let pinItem = NSMenuItem()
    /// Open surfaces, keyed by identity so a second click raises the window that is
    /// already up instead of stacking another copy.
    private var windows: [String: NSWindow] = [:]

    init(
        panel: PanelController,
        coordinator: PanelCoordinator,
        defaults: UserDefaults = .standard
    ) {
        self.panel = panel
        self.coordinator = coordinator
        self.defaults = defaults
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        item.button?.image = NSImage(
            systemSymbolName: "square.grid.3x3.fill",
            accessibilityDescription: "Virtual Codex Micro"
        )
        item.button?.toolTip = "Virtual Codex Micro"
        // VoiceOver reaches the menu bar with Ctrl-F8 and reads the button, so it
        // needs a name of its own — the symbol's description does not survive into
        // the button's accessibility label.
        item.button?.setAccessibilityLabel("Virtual Codex Micro")
        // Gives the item a stable identity, which is what lets a Cmd-drag stick.
        // That matters more than it sounds: on a notched Mac with a busy menu bar
        // macOS lays items out right to left and ours, added last, landed *inside
        // the notch* on this machine — present, visible as far as AppKit is
        // concerned, and not on screen. Moving it is the user's only remedy and
        // without this name the move is forgotten on the next launch.
        item.autosaveName = "VirtualCodexMicro.status"
        item.menu = buildMenu()
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        toggleItem.title = Self.toggleTitle(isVisible: panel.isVisible)
        toggleItem.target = self
        toggleItem.action = #selector(togglePanel)
        menu.addItem(toggleItem)

        pinItem.title = "Keep Panel Pinned"
        pinItem.target = self
        pinItem.action = #selector(togglePin)
        menu.addItem(pinItem)

        // The fix for the observed failure that a toggle alone cannot solve: with a
        // second display connected, a frame saved on it is legitimate, so
        // `clampedFrame` correctly leaves it there — and the user still cannot see
        // the panel. This is the escape hatch.
        let recentre = NSMenuItem(
            title: "Bring Panel to Main Screen", action: #selector(recentrePanel), keyEquivalent: ""
        )
        recentre.target = self
        menu.addItem(recentre)

        menu.addItem(.separator())

        for (title, selector) in [
            ("Setup & Permissions…", #selector(openOnboardingItem)),
            ("Keys & Presets…", #selector(openKeyMap)),
            ("Activity Log…", #selector(openActivityLog)),
        ] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit Virtual Codex Micro", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    /// Both dynamic titles are recomputed as the menu opens rather than tracked:
    /// the panel's visibility and pin state can change from the hotkey, from a
    /// click, or from focus loss, and a cached title is a title that lies.
    func menuNeedsUpdate(_ menu: NSMenu) {
        toggleItem.title = Self.toggleTitle(isVisible: panel.isVisible)
        pinItem.state = panel.isPinned ? .on : .off
    }

    // MARK: - Actions

    @objc private func togglePanel() {
        if panel.isVisible { panel.hide() } else { panel.showAndTakeKeyboardFocus() }
    }

    @objc private func togglePin() {
        panel.togglePinned()
    }

    @objc private func recentrePanel() {
        let window = panel.window
        window.setFrame(
            PanelController.defaultFrame(
                size: window.frame.size, screens: PanelController.visibleScreenFrames()
            ),
            display: true
        )
        panel.show()
    }

    @objc private func openOnboardingItem() {
        openOnboarding()
    }

    @objc private func openKeyMap() {
        present(
            "keymap", title: "Keys & Presets", size: CGSize(width: 420, height: 600),
            KeyMapEditorView(store: KeyMapStore())
        )
    }

    @objc private func openActivityLog() {
        present(
            "activity", title: "Activity", size: CGSize(width: 460, height: 420),
            ActivityWindow(coordinator: coordinator)
        )
    }

    /// Open one surface by name, through the same methods the menu items call.
    ///
    /// Exists to make the wiring checkable: whether a menu item opens the right
    /// window cannot be asserted in a pure check and cannot be driven from outside
    /// the process without an Accessibility grant, so the alternative is a human
    /// with a mouse every time. `VCM_MENU=onboarding|keymap|activity`.
    func open(_ surface: String) {
        switch surface {
        case "onboarding": openOnboarding()
        case "keymap": openKeyMap()
        case "activity": openActivityLog()
        default:
            FileHandle.standardError.write(Data("unknown surface: \(surface)\n".utf8))
        }
    }

    // MARK: - Onboarding

    /// First launch, hooks absent. Called once from the delegate.
    func presentOnboardingIfNeeded() {
        let installed = OnboardingView.liveStatus().hooks == .installed
        guard Self.shouldPresentOnboarding(
            hooksInstalled: installed,
            alreadyOffered: defaults.bool(forKey: Self.offeredKey)
        ) else { return }
        openOnboarding()
    }

    /// `Actions.live` unchanged except for the two closures that only a window owner
    /// can supply. Nothing here writes: `live.plan` computes the diff, `live.apply`
    /// is reached only by the Install hooks button inside the view, and the view's
    /// `.task` calls `recheck` and `plan` — never `apply`. That separation is the
    /// consent step, and it is why this passes `.live` rather than installing here.
    private func openOnboarding() {
        defaults.set(true, forKey: Self.offeredKey)
        var actions = OnboardingView.Actions.live
        actions.finish = { [weak self] in self?.close("onboarding") }
        actions.declineHooks = { [weak self] in self?.close("onboarding") }
        present(
            "onboarding", title: "Setup & Permissions", size: CGSize(width: 600, height: 700),
            OnboardingView(layout: .regular, actions: actions)
        )
    }

    // MARK: - Windows

    /// A plain titled window per surface. These are the only ordinary windows this
    /// app has, and they are allowed to activate it: a user who picked a menu item
    /// asked for a window, unlike the panel, whose whole contract is not stealing
    /// focus from the editor.
    ///
    /// `size` is given per surface rather than left to the hosting controller's
    /// fitting size, which is not optional: onboarding is a `ScrollView` and has no
    /// intrinsic height, so it opened as a 173x32 sliver — a window that exists,
    /// reports itself visible, and shows the user nothing.
    private func present<Content: View>(
        _ key: String, title: String, size: CGSize, _ content: Content
    ) {
        if let existing = windows[key] {
            raise(existing)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(size)
        window.center()
        windows[key] = window
        raise(window)
    }

    /// `orderFrontRegardless` as well as activating, and it is the line that makes
    /// this work at all.
    ///
    /// macOS 14 activation is cooperative: an `.accessory` app asking to activate
    /// without a user event in hand is refused. `makeKeyAndOrderFront` then only
    /// raises the window within our own app, so it opened *behind* whatever was
    /// frontmost — created, on screen by every measure AppKit reports, and invisible.
    /// That is the same failure mode as the one this whole file exists to fix, so it
    /// gets the same remedy the panel already uses.
    private func raise(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate()
    }

    private func close(_ key: String) {
        windows[key]?.close()
    }

    /// Dropped rather than kept hidden, so reopening rebuilds the view and re-reads
    /// the settings file. A cached onboarding window would show the diff as it was
    /// before the user installed the hooks.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows = windows.filter { $0.value !== window }
    }
}

/// The log is a lock-guarded reference type, not observable, so the live view reads
/// the coordinator's published snapshot instead of the log itself.
private struct ActivityWindow: View {
    @ObservedObject var coordinator: PanelCoordinator

    var body: some View {
        ActivityLogView(entries: coordinator.activity, dropped: coordinator.log.dropped)
    }
}

// MARK: - Self check

extension MenuBarItem {
    /// Empty when healthy.
    ///
    ///     failures += MenuBarItem.selfCheckFailures().map { "menubar: \($0)" }
    nonisolated static func selfCheckFailures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // First-launch detection, all four combinations. The two that matter are the
        // diagonal: hooks absent and never asked is the only case that opens a
        // window, and hooks present must never open one however many times the app
        // has launched.
        check("hooks absent on a first launch does not present onboarding",
              shouldPresentOnboarding(hooksInstalled: false, alreadyOffered: false))
        check("hooks present still presents onboarding",
              !shouldPresentOnboarding(hooksInstalled: true, alreadyOffered: false))
        check("onboarding is offered again after the user has answered",
              !shouldPresentOnboarding(hooksInstalled: false, alreadyOffered: true))
        check("hooks present and already offered presents onboarding",
              !shouldPresentOnboarding(hooksInstalled: true, alreadyOffered: true))

        // The toggle names the action. Same title for both states would be a menu
        // item whose effect you have to guess.
        check("the toggle item does not offer to show a hidden panel",
              toggleTitle(isVisible: false).contains("Show"))
        check("the toggle item does not offer to hide a visible panel",
              toggleTitle(isVisible: true).contains("Hide"))

        return failures
    }
}
