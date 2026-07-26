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

/// Integration probe: report what the live sources actually see on this machine
/// and exit. No window, no hooks installed, read-only. Exists because "the panel
/// shows six keys" says nothing about whether those keys came from real sessions —
/// stale bindings from an earlier run look identical to fresh discovery.
if ProcessInfo.processInfo.environment["VCM_PROBE"] != nil {
    let live = ClaudeTranscriptSource.liveSessions()
    var source = ClaudeTranscriptSource()
    let readings = source.poll(now: Date(), liveSessions: live)

    print("live claude processes with a --session-id: \(live.count)")
    for (id, pid) in live.sorted(by: { $0.key < $1.key }) {
        print("  pid \(pid)  \(id)")
    }
    print("\ntranscript readings: \(readings.count)")
    let interesting = readings.filter { $0.state != .unknown }
    print("  states resolved: \(interesting.count), abstained to unknown: \(readings.count - interesting.count)")
    for r in readings.sorted(by: { $0.observedAt > $1.observedAt }).prefix(12) {
        let pid = r.pid.map(String.init) ?? "-"
        print("  \(r.state.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)) pid=\(pid.padding(toLength: 6, withPad: " ", startingAt: 0)) \(r.sessionID.prefix(8))  \(r.reason)")
    }
    let hookSpool = ClaudeHookSource.defaultSpoolDirectory
    let spoolExists = FileManager.default.fileExists(atPath: hookSpool.path)
    print("\nhook spool: \(spoolExists ? "present" : "ABSENT — hooks are not installed, so needsInput can never fire")")
    print("hook events waiting: \(ClaudeHookSource().drainNow().count)")
    exit(0)
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
