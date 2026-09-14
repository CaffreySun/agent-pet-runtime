import Foundation

/// Normalized event kind. Every adapter reduces its agent's private vocabulary
/// to one of these before the event reaches the `ActivityEngine`.
public enum AgentEventKind: String, Codable, Sendable, Equatable, CaseIterable {
    case sessionStarted
    case working
    case waitingInput
    case waitingApproval
    case completed
    case failed
    case sessionClosed
    /// A status-line reading: tokens used, session name, project. It describes
    /// a session, it does not change one — see `AgentEvent.context`.
    case contextUpdate
}

public struct FocusTarget: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case directory
        case file
        case none
    }
    public let kind: Kind
    public let path: String?

    public init(kind: Kind, path: String?) {
        self.kind = kind
        self.path = path
    }

    /// v0.1 cannot reliably raise another app's window: hook payloads carry no
    /// terminal identity. Opening the project directory is the honest fallback.
    public static func openingDirectory(_ url: URL) -> FocusTarget {
        FocusTarget(kind: .directory, path: url.path)
    }

    public static let unavailable = FocusTarget(kind: .none, path: nil)
}

public struct AgentEvent: Sendable, Equatable {
    public let agentID: String
    public let sessionID: String
    public let kind: AgentEventKind
    public let at: Date
    public let confidence: EventConfidence

    /// Short human-readable context, e.g. the tool being run.
    ///
    /// For some events this is the user's own prompt — which is why it is
    /// never the source of the panel's "current tool" and never goes on a
    /// floating panel. See `toolName`.
    public let summary: String?
    public let detail: String?
    /// The tool an event names, when the rule says which field holds it.
    ///
    /// Separate from `summary` on purpose: `summary` is whatever the rule
    /// thought was interesting, while this is only ever a tool name — the one
    /// kind of summary that is safe to draw beside the pet.
    public let toolName: String?
    public let projectPath: URL?
    public let focusTarget: FocusTarget?

    /// Status-line readings ride along as their own kind of event.
    public let context: SessionContext?

    /// Best-effort unique id from the agent's payload, used for deduplication.
    public let eventID: String?

    /// The agent process this event came from — the shim's parent, which is the
    /// agent itself. Set on everything that arrives over the bridge, and on the
    /// placeholders a process scan creates, so the first real event from a
    /// process replaces what was guessed about it.
    public let processID: Int32?

    /// True for a session the runtime inferred from the process table rather
    /// than heard from: it exists, and that is all that is known about it.
    public let isPlaceholder: Bool

    public init(
        agentID: String,
        sessionID: String,
        kind: AgentEventKind,
        at: Date,
        confidence: EventConfidence,
        summary: String? = nil,
        detail: String? = nil,
        toolName: String? = nil,
        projectPath: URL? = nil,
        focusTarget: FocusTarget? = nil,
        context: SessionContext? = nil,
        eventID: String? = nil,
        processID: Int32? = nil,
        isPlaceholder: Bool = false
    ) {
        self.agentID = agentID
        self.sessionID = sessionID
        self.kind = kind
        self.at = at
        self.confidence = confidence
        self.summary = summary
        self.detail = detail
        self.toolName = toolName
        self.projectPath = projectPath
        self.focusTarget = focusTarget
        self.context = context
        self.eventID = eventID
        self.processID = processID
        self.isPlaceholder = isPlaceholder
    }
}

public extension AgentEventKind {
    /// The state this event puts a session into. `sessionClosed` removes the
    /// session instead, and a context update has no state of its own — it
    /// describes a session rather than moving it.
    var resultingState: AgentState? {
        switch self {
        case .sessionStarted:   return .idle
        case .working:          return .running
        case .waitingInput:     return .waitingInput
        case .waitingApproval:  return .waitingApproval
        case .completed:        return .completed
        case .failed:           return .failed
        case .sessionClosed, .contextUpdate: return nil
        }
    }

    /// Confidence of a natively reported event. Process-scan and inference
    /// adapters must construct their events with a lower level explicitly.
    var nativeConfidenceLevel: ConfidenceLevel { .high }
}
