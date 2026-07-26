import AppKit
import SwiftUI

/// App entry. Composes the panel shell, the control surface and — for now — the
/// mock backend, so the surface is demonstrable before any real adapter lands.
/// Swapping MockBackend for a real one is a change to `driveStates()` only.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PanelController?
    private let backend = MockBackend()
    private let model = PanelModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let controller = PanelController(
            content: PanelHost(model: model),
            layout: .regular
        )
        panel = controller
        controller.show()

        if let prefix = ProcessInfo.processInfo.environment["VCM_RENDER"] {
            OffscreenRender.run(pathPrefix: prefix)
        }

        installHotkeys(controller)
        driveStates()

        if ProcessInfo.processInfo.environment["VCM_SMOKE"] != nil {
            let seconds = Double(ProcessInfo.processInfo.environment["VCM_SMOKE"] ?? "2") ?? 2
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    private func installHotkeys(_ controller: PanelController) {
        do {
            // Summon takes keyboard focus explicitly: a hotkey that shows the panel
            // but leaves it unable to accept Tab would make every key unreachable
            // for a keyboard-only user, which the a11y audit called out.
            try HotkeyCenter.shared.bind(.summon, to: HotkeyCenter.Action.summon.defaultBinding) {
                MainActor.assumeIsolated {
                    controller.isVisible ? controller.hide() : controller.showAndTakeKeyboardFocus()
                }
            }
            try HotkeyCenter.shared.bind(.pin, to: HotkeyCenter.Action.pin.defaultBinding) {
                MainActor.assumeIsolated { controller.togglePinned() }
            }
        } catch {
            // A shortcut already owned system-wide is a real, reportable condition,
            // not something to swallow — task 030 surfaces this in onboarding.
            FileHandle.standardError.write(Data("hotkey registration failed: \(error)\n".utf8))
        }
    }

    /// Bind the mock's sessions to slots in order, then follow its state stream.
    private func driveStates() {
        Task { @MainActor in
            let sessions = (try? await backend.discoverSessions()) ?? []
            for (slot, session) in sessions.prefix(PanelLayout.agentKeyCount).enumerated() {
                model.sessions[slot] = session
                model.states[slot] = session.state
            }
            model.capabilities = sessions.first?.capabilities ?? .observed

            for await updated in backend.stateUpdates() {
                guard let slot = model.sessions.first(where: { $0.value.id == updated.id })?.key
                else { continue }
                model.sessions[slot] = updated
                model.states[slot] = updated.state
            }
        }
    }
}

/// Observable surface state. Deliberately thin — the state engine and registry
/// own the real logic; this only carries what the views render.
@MainActor
final class PanelModel: ObservableObject {
    @Published var states: [Int: AgentState] = [:]
    @Published var sessions: [Int: AgentSession] = [:]
    @Published var capabilities: SessionCapabilities = .observed
}

private struct PanelHost: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        PanelRootView(
            layout: .regular,
            states: model.states,
            sessions: model.sessions,
            capabilities: model.capabilities,
            canSpawnSessions: true,
            onAgentKey: { slot in
                // Focus is task 024; log until FocusResolver is wired.
                print("agent key \(slot) -> focus \(model.sessions[slot]?.title ?? "unbound")")
            },
            onCommand: { slot in print("command \(slot)") },
            onPreset: { direction in print("preset \(direction)") },
            onOpenChooser: { print("open preset chooser") }
        )
    }
}

if ProcessInfo.processInfo.environment["VCM_SELFTEST"] != nil {
    SelfCheck.run()
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
