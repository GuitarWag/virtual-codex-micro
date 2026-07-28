import Foundation

/// What a bound session will actually accept. Declared per session, not per
/// backend: a session the app spawned under its own PTY accepts approvals on
/// stdin, while one the user started in their own terminal can only be observed
/// and focused. Same provider, different capabilities.
///
/// Command keys read this to decide enabled state. A key that cannot act must
/// look disabled rather than fail silently on click.
public struct SessionCapabilities: OptionSet, Sendable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let focus = SessionCapabilities(rawValue: 1 << 0)
    public static let approve = SessionCapabilities(rawValue: 1 << 1)
    public static let reject = SessionCapabilities(rawValue: 1 << 2)
    public static let sendPrompt = SessionCapabilities(rawValue: 1 << 3)
    public static let setEffort = SessionCapabilities(rawValue: 1 << 4)

    /// A session we spawned and control end to end.
    public static let owned: SessionCapabilities = [.focus, .approve, .reject, .sendPrompt, .setEffort]
    /// A session we can see and raise, but must not type into.
    public static let observed: SessionCapabilities = [.focus]
}

/// How much to trust a state reading. Hook-delivered events beat inference from
/// a transcript tail, so when two sources disagree the engine has a rule to
/// apply instead of a coin flip.
public enum StateConfidence: Int, Comparable, Sendable, Codable {
    case inferred
    case reported
    /// A human said so, for a bounded window.
    ///
    /// Above `reported` because a forced colour that live sources can overwrite is
    /// useless exactly where it is wanted: forcing a state on the session that is
    /// doing the work fails within milliseconds, since its own tool calls emit
    /// fresher `reported` readings and arbitration breaks ties on evidence time.
    /// Observed — three attempts to force green on an active session all lost to the
    /// next PreToolUse.
    ///
    /// Safe only because it expires. See `StateSource.manualTest`, whose 45s
    /// threshold is asserted precisely so this tier cannot make the panel lie
    /// indefinitely.
    case forced

    public static func < (a: StateConfidence, b: StateConfidence) -> Bool { a.rawValue < b.rawValue }
}

public struct AgentSession: Identifiable, Sendable, Codable {
    public let id: String
    public var backendID: String
    public var title: String
    public var repoPath: String?
    public var branch: String?
    public var state: AgentState
    public var confidence: StateConfidence
    public var capabilities: SessionCapabilities
    public var lastTransition: Date

    public init(
        id: String,
        backendID: String,
        title: String,
        repoPath: String? = nil,
        branch: String? = nil,
        state: AgentState = .unknown,
        confidence: StateConfidence = .inferred,
        capabilities: SessionCapabilities = .observed,
        lastTransition: Date = Date()
    ) {
        self.id = id
        self.backendID = backendID
        self.title = title
        self.repoPath = repoPath
        self.branch = branch
        self.state = state
        self.confidence = confidence
        self.capabilities = capabilities
        self.lastTransition = lastTransition
    }
}

public enum AgentCommand: Sendable, Equatable {
    case focus
    case approve
    case reject
    case newSession
    case sendPrompt(String)
    case setEffort(Int)
}

/// The single boundary the UI talks to. No view may branch on which backend it
/// is dealing with — if that ever becomes necessary, this protocol is wrong.
public protocol AgentBackend: AnyObject, Sendable {
    var id: String { get }
    var displayName: String { get }

    func discoverSessions() async throws -> [AgentSession]
    /// Continuous stream of state changes. Emitting `.unknown` when a source
    /// goes quiet is required, not optional.
    func stateUpdates() -> AsyncStream<AgentSession>
    func dispatch(_ command: AgentCommand, to sessionID: String) async throws
}
