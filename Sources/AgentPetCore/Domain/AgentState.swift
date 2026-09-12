import Foundation

/// The normalized state of an agent session.
///
/// Every adapter — regardless of the source agent's private vocabulary — must
/// reduce to one of these eight values before events reach the `ActivityEngine`.
public enum AgentState: String, Codable, Sendable, CaseIterable {
    case idle
    case running
    case waitingInput
    case waitingApproval
    case completed
    case failed
    case paused
    case unknown
}

/// Priority class ordering used by the `ActivityEngine`.
///
/// Lower raw values win. Within a class, tie-breaks are applied separately —
/// see `ActivityEngine`.
public enum PriorityClass: Int, Comparable, Sendable, CaseIterable {
    /// The user is blocked and must act.
    case attention = 0
    /// The session ended badly.
    case failure = 1
    /// Work in progress.
    case active = 2
    /// Work just finished.
    case settled = 3
    /// Nothing to show.
    case inactive = 4

    public static func < (lhs: PriorityClass, rhs: PriorityClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public extension AgentState {
    var priorityClass: PriorityClass {
        switch self {
        case .waitingInput, .waitingApproval: return .attention
        case .failed:                         return .failure
        case .running:                        return .active
        case .completed:                      return .settled
        case .idle, .unknown, .paused:        return .inactive
        }
    }

    /// Whether this state means "the user must act before the agent can proceed".
    var blocksOnUser: Bool {
        self == .waitingInput || self == .waitingApproval
    }

    /// How long this state may go without an event before it degrades.
    /// `nil` means the state never times out on silence.
    var staleTimeout: TimeInterval? {
        switch self {
        case .running:          return 30
        case .unknown:          return 60
        case .waitingApproval:  return 300
        case .failed:           return 600
        case .waitingInput:     return nil
        case .idle:             return nil
        case .paused:           return nil
        case .completed:        return nil  // driven by completionDwell, not silence
        }
    }

    /// The state this one degrades to after `staleTimeout` elapses.
    var staleSuccessor: AgentState? {
        switch self {
        case .running:          return .unknown
        case .unknown:          return .idle
        case .waitingApproval:  return .unknown
        case .failed:           return .idle
        case .waitingInput, .idle, .paused, .completed: return nil
        }
    }
}
