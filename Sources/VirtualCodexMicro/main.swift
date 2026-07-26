import AppKit
import SwiftUI

/// App entry. Owns the panel shell and the coordinator; everything else hangs off
/// those two. `MockBackend` still drives state, deliberately: the real adapters
/// exist but installing hooks writes the user's config, so that path waits behind
/// onboarding consent rather than happening on first launch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: PanelController?
    /// Held for the process's lifetime: `NSStatusBar` does not retain the item, and
    /// a released one disappears from the menu bar — which is the failure this exists
    /// to prevent.
    private var menuBar: MenuBarItem?
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
        // After the hotkey attempt on purpose: this is the route that works when
        // that registration lost a conflict, so it must not depend on it.
        let menu = MenuBarItem(panel: controller, coordinator: coordinator)
        menuBar = menu
        coordinator.start()

        // First launch with no hooks installed. Opens the consent screen; installing
        // still needs the button on it, and the screen writes nothing by appearing.
        menu.presentOnboardingIfNeeded()

        // Open one menu surface at launch, so the menu wiring can be looked at
        // without a human driving the mouse. Calls the same methods the items do.
        if let surface = ProcessInfo.processInfo.environment["VCM_MENU"] {
            menu.open(surface)
            // Report where each window actually landed. Not decoration: onboarding
            // opened as a 173x32 sliver that reported itself visible, and a
            // screenshot of the wrong Space cannot tell that apart from "did not
            // open at all". The window server's own numbers can.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                for window in NSApp.windows where !window.title.isEmpty {
                    FileHandle.standardError.write(Data(
                        "\(window.title): visible=\(window.isVisible) frame=\(window.frame)\n".utf8
                    ))
                }
            }
        }

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
/// Show the settings.json change the hook installer WOULD make, and exit without
/// making it. This is the consent step: the installer deliberately separates
/// planning from applying so the diff can be reviewed before anything is written.
if ProcessInfo.processInfo.environment["VCM_HOOKPLAN"] != nil {
    do {
        let plan = try ClaudeHookInstaller.plan(.install)
        print("settings file : \(plan.settingsURL.path)")
        print("backup to     : \(plan.backupURL.lastPathComponent)")
        print("forwarder     : \(plan.forwarderURL.path)")
        print("spool         : \(plan.spoolDirectory.path)")
        print("events        : \(plan.events.count) — \(plan.events.joined(separator: ", "))")
        print("no-op         : \(plan.isNoOp)")
        print("reformats file: \(plan.reformatsFile)   <- canonical re-serialisation reorders keys and re-indents")
        print("\n--- diff ---")
        print(plan.diff)
    } catch {
        print("PLAN REFUSED: \(error)")
    }
    exit(0)
}

/// Apply or remove the hooks. Separate flag from VCM_HOOKPLAN on purpose: the
/// only path that writes the user's config must be explicitly asked for, never a
/// side effect of inspecting it.
///   VCM_HOOKAPPLY=install   VCM_HOOKAPPLY=uninstall
if let action = ProcessInfo.processInfo.environment["VCM_HOOKAPPLY"] {
    do {
        let plan = try ClaudeHookInstaller.plan(action == "uninstall" ? .uninstall : .install)
        if plan.isNoOp {
            print("no change needed — already in the requested state")
            exit(0)
        }
        try ClaudeHookInstaller.apply(plan)
        print("applied \(action) to \(plan.settingsURL.path)")
        print("backup: \(plan.backupURL.path)")
        print("events: \(plan.events.count)")
        print("forwarder: \(plan.forwarderURL.path)")
        print("spool: \(plan.spoolDirectory.path)")
    } catch {
        print("REFUSED: \(error)")
        exit(1)
    }
    exit(0)
}

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
