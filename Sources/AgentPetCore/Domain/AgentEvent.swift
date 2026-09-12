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
    public let summary: String?
    public let detail: String?
    public let projectPath: URL?
    public let focusTarget: FocusTarget?

    /// Best-effort unique id from the agent's payload, used for deduplication.
    public let eventID: String?

    public init(
        agentID: String,
        sessionID: String,
        kind: AgentEventKind,
        at: Date,
        confidence: EventConfidence,
        summary: String? = nil,
        detail: String? = nil,
        projectPath: URL? = nil,
        focusTarget: FocusTarget? = nil,
        eventID: String? = nil
    ) {
        self.agentID = agentID
        self.sessionID = sessionID
        self.kind = kind
        self.at = at
        self.confidence = confidence
        self.summary = summary
        self.detail = detail
        self.projectPath = projectPath
        self.focusTarget = focusTarget
        self.eventID = eventID
    }
}

public extension AgentEventKind {
    /// The state this event puts a session into. `sessionClosed` removes the
    /// session instead, so it has no state.
    var resultingState: AgentState? {
        switch self {
        case .sessionStarted:   return .idle
        case .working:          return .running
        case .waitingInput:     return .waitingInput
        case .waitingApproval:  return .waitingApproval
        case .completed:        return .completed
        case .failed:           return .failed
        case .sessionClosed:    return nil
        }
    }

    /// Confidence of a natively reported event. Process-scan and inference
    /// adapters must construct their events with a lower level explicitly.
    var nativeConfidenceLevel: ConfidenceLevel { .high }
}
