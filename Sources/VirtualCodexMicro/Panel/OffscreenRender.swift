import AppKit
import SwiftUI

/// Renders the control surface to a PNG without showing a window.
///
/// Exists because `screencapture` needs Screen Recording permission, which is
/// denied from a CLI context on this machine and fails with a plain error and no
/// dialog — the same TCC pattern the focus spike documented. Rendering our own
/// view tree needs no permission at all, so visual verification stays possible
/// in CI and on a locked-down machine.
///
/// Run: `VCM_RENDER=/tmp/out ./VirtualCodexMicro` → writes `-light.png` and
/// `-dark.png`. Also a cheap regression artifact: diff the PNGs across a change.
@MainActor
enum OffscreenRender {
    static func run(pathPrefix: String) -> Never {
        var written: [String] = []

        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                         ("dark", NSAppearance.Name.darkAqua)] {
            let layout = PanelLayout.regular
            let view = PanelRootView(
                layout: layout,
                states: demoStates,
                sessions: demoSessions,
                capabilities: .observed,   // shows the disabled command treatment
                canSpawnSessions: true,
                onAgentKey: { _ in }, onCommand: { _ in },
                onPreset: { _ in }, onOpenChooser: {}
            )

            let host = NSHostingView(rootView: view)
            host.frame = CGRect(origin: .zero, size: layout.panelSize)
            host.appearance = NSAppearance(named: appearanceName)

            // A hosting view outside a window renders with unresolved materials,
            // so park it in an offscreen window first.
            let window = NSWindow(
                contentRect: host.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.appearance = NSAppearance(named: appearanceName)
            window.contentView = host
            window.layoutIfNeeded()
            host.layoutSubtreeIfNeeded()

            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                fail("could not allocate a bitmap for \(suffix)")
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                fail("could not encode PNG for \(suffix)")
            }

            let path = "\(pathPrefix)-\(suffix).png"
            do { try png.write(to: URL(fileURLWithPath: path)) }
            catch { fail("could not write \(path): \(error)") }
            written.append("\(path) (\(Int(layout.panelSize.width))x\(Int(layout.panelSize.height)), \(png.count) bytes)")
        }

        for line in written { print("rendered \(line)") }
        exit(0)
    }

    /// One of each interesting state, so a render doubles as a visual state chart.
    private static let demoStates: [Int: AgentState] = [
        0: .running, 1: .needsInput, 2: .complete,
        3: .error, 4: .unknown, 5: .unassigned
    ]

    private static let demoSessions: [Int: AgentSession] = [
        0: AgentSession(id: "d0", backendID: "demo", title: "api refactor", repoPath: "~/work/api", branch: "main", state: .running),
        1: AgentSession(id: "d1", backendID: "demo", title: "flaky test", repoPath: "~/work/api", branch: "fix/flake", state: .needsInput),
        2: AgentSession(id: "d2", backendID: "demo", title: "changelog", repoPath: "~/work/docs", branch: "main", state: .complete),
        3: AgentSession(id: "d3", backendID: "demo", title: "migration", repoPath: "~/work/db", branch: "wip", state: .error),
        4: AgentSession(id: "d4", backendID: "demo", title: "ledger sync", repoPath: "~/work/fin", branch: "main", state: .unknown)
    ]

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("render FAILED: \(message)\n".utf8))
        exit(1)
    }
}
