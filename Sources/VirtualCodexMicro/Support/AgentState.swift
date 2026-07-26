import Foundation

/// The normalized agent states every backend maps into. Deliberately closed:
/// providers may expose finer detail, but the panel only ever renders these,
/// so the user learns one status vocabulary rather than one per tool.
///
/// `unknown` is distinct from `unassigned` and matters more than it looks —
/// it is what a key shows when a slot is bound but its state source went quiet.
/// Rendering a stale colour instead is the drift failure the PRD names as its
/// first risk, so "we lost track" must be representable.
public enum AgentState: String, CaseIterable, Sendable, Codable {
    case unassigned
    case idle
    case running
    case complete
    case needsInput
    case error
    case unknown

    /// Short label shown beside the key. Status is never colour-only.
    public var label: String {
        switch self {
        case .unassigned: "empty"
        case .idle: "idle"
        case .running: "running"
        case .complete: "done"
        case .needsInput: "waiting"
        case .error: "error"
        case .unknown: "unknown"
        }
    }

    /// Whether this state should draw attention. Drives overflow ordering when
    /// there are more sessions than slots, so a blocked agent is never hidden.
    public var isAttentionWorthy: Bool {
        self == .needsInput || self == .error
    }
}
