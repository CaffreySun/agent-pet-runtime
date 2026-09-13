import Foundation

/// One live session's contribution to what the pet should show.
public struct AgentActivity: Sendable, Equatable, Identifiable {
    /// Stable across the session's lifetime: `"<agentID>/<sessionID>"`.
    public let id: String
    public let agentID: String
    public let sessionID: String

    public internal(set) var state: AgentState
    public internal(set) var confidence: EventConfidence
    public internal(set) var title: String?
    public internal(set) var detail: String?
    /// The last tool this session was seen using. Set only from events whose
    /// rule names a tool field, so a prompt that lands in `title` can never
    /// masquerade as one.
    public internal(set) var toolName: String?
    public internal(set) var focusTarget: FocusTarget?
    /// What the session's status line reported, when one is tapped.
    public internal(set) var context: SessionContext?
    public let startedAt: Date
    public internal(set) var updatedAt: Date

    /// When the session entered its *current* state. Aging and the completion
    /// dwell both measure from here, and it deliberately survives repeated
    /// events that do not change the state.
    public internal(set) var enteredStateAt: Date

    public init(
        agentID: String,
        sessionID: String,
        state: AgentState,
        confidence: EventConfidence,
        title: String? = nil,
        detail: String? = nil,
        toolName: String? = nil,
        focusTarget: FocusTarget? = nil,
        context: SessionContext? = nil,
        startedAt: Date,
        updatedAt: Date,
        enteredStateAt: Date
    ) {
        self.id = agentID + "/" + sessionID
        self.agentID = agentID
        self.sessionID = sessionID
        self.state = state
        self.confidence = confidence
        self.title = title
        self.detail = detail
        self.toolName = toolName
        self.focusTarget = focusTarget
        self.context = context
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.enteredStateAt = enteredStateAt
    }

    public var key: SessionKey {
        SessionKey(agentID: agentID, sessionID: sessionID)
    }
}

/// Identifies a session across agents. Two agents may reuse the same session
/// string, so the agent id is part of the key.
public struct SessionKey: Hashable, Sendable {
    public let agentID: String
    public let sessionID: String

    public init(agentID: String, sessionID: String) {
        self.agentID = agentID
        self.sessionID = sessionID
    }
}

/// Injectable time source. Every scheduling decision the engine makes is a
/// function of `now`, so tests drive it directly instead of sleeping.
public protocol ActivityClock: Sendable {
    var now: Date { get }
}

public struct SystemActivityClock: ActivityClock, Sendable {
    public init() {}
    public var now: Date { Date() }
}

/// A clock the test suite advances by hand.
public final class ManualActivityClock: ActivityClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    public init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        current = start
    }

    public var now: Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    public func advance(by interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }

    public func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }
        current = date
    }
}
