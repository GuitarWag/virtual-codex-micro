// Feeds the REAL captured spool bytes through the app's own HookEvent.parse and
// ClaudeHookSource.outcome(for:). Not a re-implementation and not a reading of
// the table — the shipped code, the payload a real interactive session produced.
//
// Build (compiles the app's sources directly, writes nothing into the project):
//   swiftc -o /tmp/mapcheck \
//     Sources/VirtualCodexMicro/Support/AgentState.swift \
//     Sources/VirtualCodexMicro/Backends/ClaudeHookSource.swift \
//     Sources/VirtualCodexMicro/Backends/ClaudeHookInstaller.swift \
//     spikes/needsinput/mapcheck.swift
//
// Deliberately does NOT call ClaudeHookInstaller.selfCheckFailures(): that runs
// an uninstall, and apply() removes ~/.virtual-codex-micro unconditionally, so
// the self-check destroys the live install. See FINDINGS.md.
import Foundation

var bad = 0
for path in CommandLine.arguments.dropFirst() {
    guard let data = FileManager.default.contents(atPath: path) else {
        print("MISSING \(path)"); bad += 1; continue
    }
    guard let event = HookEvent.parse(data, observedAt: Date()) else {
        print("UNPARSEABLE \(path)"); bad += 1; continue
    }
    let outcome = event.outcome
    print("\(event.name.padding(toLength: 20, withPad: " ", startingAt: 0)) -> \(outcome)")
    if event.name == "PermissionRequest" {
        guard outcome == .state(.needsInput) else {
            print("  FAIL: PermissionRequest did not map to needsInput"); bad += 1; continue
        }
        print("  tool_name           : \(event.toolName ?? "nil")")
        print("  tool_input.command  : \(event.toolInput?["command"]?.stringValue ?? "nil")")
        print("  suggestions present : \(event.permissionSuggestions != nil)")
        print("  claudePID / term    : \(event.claudePID.map(String.init) ?? "nil") / \(event.termProgram ?? "nil")")
        print("  agentID (must be nil): \(event.agentID ?? "nil")")
        print("  colour              : \(AgentState.needsInput.rawValue)")
    }
}
print(bad == 0 ? "mapcheck OK" : "mapcheck FAILED (\(bad))")
exit(bad == 0 ? 0 : 1)
