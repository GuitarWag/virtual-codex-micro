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

        for (suffix, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let layout = PanelLayout.regular
            let view = PanelRootView(
                coordinator: .demo(
                    states: demoStates(suffix),
                    sessions: demoSessions(suffix),
                    capabilities: .observed   // shows the disabled command treatment
                ),
                layout: layout
            )

            // ImageRenderer, NOT NSHostingView.cacheDisplay.
            //
            // The M1 review proved cacheDisplay(in:to:) can drop a blurred layer
            // entirely — which is precisely the case underglow, the one thing on
            // this panel made of blur. Both the committed reference PNGs and the
            // pixel-based colour check were therefore measuring an image the user
            // never sees, and understating the glow. A verification tool that
            // silently omits a layer is worse than none: it produces confident
            // wrong numbers.
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
            renderer.scale = 2
            renderer.proposedSize = ProposedViewSize(layout.panelSize)

            guard let cgImage = renderer.cgImage else {
                fail("ImageRenderer produced no image for \(suffix)")
            }
            let rep = NSBitmapImageRep(cgImage: cgImage)
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

    /// One of each state, so a render doubles as a visual state chart.
    ///
    /// There are seven states and six slots, so the pair takes slot 5 between
    /// them: `idle` in light and `unassigned` in dark. `idle` was missing from
    /// this set entirely, which meant the state measuring worst against the light
    /// panel was the one the review artifact could not show — and light is
    /// exactly the appearance where it fails. `unassigned` is unchanged and is
    /// meant to recede, so dark is the cheaper place to look at it.
    private static func demoStates(_ appearance: String) -> [Int: AgentState] {
        [0: .running, 1: .needsInput, 2: .complete, 3: .error, 4: .unknown,
         5: appearance == "light" ? .idle : .unassigned]
    }

    private static func demoSessions(_ appearance: String) -> [Int: AgentSession] {
        var sessions: [Int: AgentSession] = [
            0: AgentSession(id: "d0", backendID: "demo", title: "api refactor", repoPath: "~/work/api", branch: "main", state: .running),
            1: AgentSession(id: "d1", backendID: "demo", title: "flaky test", repoPath: "~/work/api", branch: "fix/flake", state: .needsInput),
            2: AgentSession(id: "d2", backendID: "demo", title: "changelog", repoPath: "~/work/docs", branch: "main", state: .complete),
            3: AgentSession(id: "d3", backendID: "demo", title: "migration", repoPath: "~/work/db", branch: "wip", state: .error),
            4: AgentSession(id: "d4", backendID: "demo", title: "ledger sync", repoPath: "~/work/fin", branch: "main", state: .unknown)
        ]
        // An idle key is a bound session doing nothing, so it needs a session to
        // name; an unassigned one is an empty slot, so it must not have one.
        if appearance == "light" {
            sessions[5] = AgentSession(id: "d5", backendID: "demo", title: "release notes", repoPath: "~/work/docs", branch: "main", state: .idle)
        }
        return sessions
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("render FAILED: \(message)\n".utf8))
        exit(1)
    }
}
