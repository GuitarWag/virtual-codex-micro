import Foundation

/// Runnable checks for the non-obvious invariants. Stands in for a test target
/// because CLT-only toolchains ship no XCTest and no swift-testing.
/// Run: `VCM_SELFTEST=1 ./.build/debug/VirtualCodexMicro` — exits 1 on failure.
///
/// Add a case here for any logic whose breakage would be silent. Skip the
/// one-liners.
enum SelfCheck {
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

        if failures.isEmpty {
            print("selfcheck: ok (\(AgentState.allCases.count) states)")
            exit(0)
        }
        for f in failures { FileHandle.standardError.write(Data("selfcheck FAIL: \(f)\n".utf8)) }
        exit(1)
    }
}
