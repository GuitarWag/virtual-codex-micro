import AppKit
import SwiftUI

/// App entry. Owns the panel shell and the coordinator; everything else hangs off
/// those two. `MockBackend` still drives state, deliberately: the real adapters
/// exist but installing hooks writes the user's config, so that path waits behind
/// onboarding consent rather than happening on first launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PanelController?
    private let coordinator = PanelCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let controller = PanelController(
            content: PanelRootView(coordinator: coordinator, layout: .regular),
            layout: .regular
        )
        panel = controller
        controller.show()

        if let prefix = ProcessInfo.processInfo.environment["VCM_RENDER"] {
            OffscreenRender.run(pathPrefix: prefix)
        }

        installHotkeys(controller)
        coordinator.start()

        if ProcessInfo.processInfo.environment["VCM_SMOKE"] != nil {
            let seconds = Double(ProcessInfo.processInfo.environment["VCM_SMOKE"] ?? "2") ?? 2
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    private func installHotkeys(_ controller: PanelController) {
        do {
            // Summon takes keyboard focus explicitly: a hotkey that shows the panel
            // but leaves it unable to accept Tab would make every key unreachable
            // for a keyboard-only user, which the a11y review called out.
            try HotkeyCenter.shared.bind(.summon, to: HotkeyCenter.Action.summon.defaultBinding) {
                MainActor.assumeIsolated {
                    controller.isVisible ? controller.hide() : controller.showAndTakeKeyboardFocus()
                }
            }
            try HotkeyCenter.shared.bind(.pin, to: HotkeyCenter.Action.pin.defaultBinding) {
                MainActor.assumeIsolated { controller.togglePinned() }
            }
        } catch {
            // A combination already owned system-wide is a real, reportable
            // condition, not something to swallow — onboarding surfaces it.
            FileHandle.standardError.write(Data("hotkey registration failed: \(error)\n".utf8))
        }
    }
}

if ProcessInfo.processInfo.environment["VCM_SELFTEST"] != nil {
    SelfCheck.run()
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
