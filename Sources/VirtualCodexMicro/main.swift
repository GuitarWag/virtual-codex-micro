import AppKit
import SwiftUI

// Smoke scaffold: proves SwiftUI + AppKit + NSPanel compile and run under a
// Command Line Tools toolchain with no Xcode present. Replaced by the real
// panel shell in task 007.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: SmokeView())
        panel.center()
        panel.orderFrontRegardless()
        self.panel = panel

        if ProcessInfo.processInfo.environment["VCM_SMOKE"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
        }
    }
}

private struct SmokeView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Virtual Codex Micro").font(.headline)
            Text("toolchain ok").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
    }
}

if ProcessInfo.processInfo.environment["VCM_SELFTEST"] != nil {
    SelfCheck.run()
}

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.run()
