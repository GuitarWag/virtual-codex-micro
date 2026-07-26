import Foundation

/// Runnable checks for the non-obvious invariants. Stands in for a test target
/// because CLT-only toolchains ship no XCTest and no swift-testing.
/// Run: `VCM_SELFTEST=1 ./.build/debug/VirtualCodexMicro` — exits 1 on failure.
///
/// Add a case here for any logic whose breakage would be silent. Skip the
/// one-liners.
enum SelfCheck {
    /// @MainActor because some module checks live on SwiftUI `View` types, which
    /// infer main-actor isolation. This runs on the main thread at startup before
    /// NSApplication exists, so the annotation costs nothing.
    @MainActor
    static func run() -> Never {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // Overflow ordering depends on this: a blocked agent must never be the
        // one hidden when there are more sessions than slots.
        check("needsInput draws attention", AgentState.needsInput.isAttentionWorthy)
        check("error draws attention", AgentState.error.isAttentionWorthy)
        check("running does not", !AgentState.running.isAttentionWorthy)
        check("unknown does not", !AgentState.unknown.isAttentionWorthy)

        // The owned-vs-observed correction rests entirely on this distinction.
        check("observed can focus", SessionCapabilities.observed.contains(.focus))
        check("observed cannot approve", !SessionCapabilities.observed.contains(.approve))
        check("observed cannot reject", !SessionCapabilities.observed.contains(.reject))
        check("owned can approve", SessionCapabilities.owned.contains(.approve))
        check("owned can set effort", SessionCapabilities.owned.contains(.setEffort))

        // Conflict resolution rule between hook events and transcript inference.
        check("reported beats inferred", StateConfidence.reported > StateConfidence.inferred)

        // Every state needs a non-empty label, or status becomes colour-only.
        check("all states labelled", AgentState.allCases.allSatisfy { !$0.label.isEmpty })

        // Module-owned invariants. Each module exposes selfCheckFailures() in its
        // own file so parallel work never contends on this one.
        failures += PanelLayout.selfCheckFailures().map { "layout: \($0)" }
        failures += StateColors.selfCheckFailures().map { "colors: \($0)" }
        failures += PanelController.selfCheckFailures().map { "panel: \($0)" }
        failures += HotkeyCenter.selfCheckFailures().map { "hotkey: \($0)" }
        failures += AgentKeyView.selfCheckFailures().map { "agentkey: \($0)" }
        failures += CommandKeyView.selfCheckFailures().map { "cmdkey: \($0)" }
        failures += DialView.selfCheckFailures().map { "dial: \($0)" }
        failures += DirectionPadView.selfCheckFailures().map { "pad: \($0)" }
        failures += MockBackend.selfCheckFailures().map { "mock: \($0)" }

        if failures.isEmpty {
            print("selfcheck: ok (\(AgentState.allCases.count) states)")
            exit(0)
        }
        for f in failures { FileHandle.standardError.write(Data("selfcheck FAIL: \(f)\n".utf8)) }
        exit(1)
    }
}
