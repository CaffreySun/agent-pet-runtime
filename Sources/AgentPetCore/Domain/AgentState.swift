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

    /// The atlas row this state is shown with.
    ///
    /// The contract names what each row *is*, not which agent state selects
    /// it, so the mapping below is this runtime's reading of those purposes:
    ///
    /// - `running` is documented as "active task work, not literal
    ///   foot-running", which is exactly what an agent does while working.
    /// - `waiting` is "an expectant asking pose for approval, help, or user
    ///   input", covering both blocking states.
    /// - `jumping` is "anticipation, lift, peak, descent, and settle" — a
    ///   celebration, and the only row that fits a task finishing well.
    /// - `waving` is "a greeting or attention gesture", which is a reaction to
    ///   the user rather than to the agent, so no state selects it. It plays
    ///   when the pet is clicked.
    /// - `running-left` and `running-right` are locomotion, chosen by which
    ///   way the pet is being dragged — never by agent state.
    ///
    /// `waitingInput` and `waitingApproval` deliberately share one row: the
    /// atlas has only one `waiting` pose, and the difference between "your
    /// turn" and "approve this" belongs in the UI, not the animation.
    var animationTrackName: String {
        switch self {
        case .idle, .paused, .unknown: return "idle"
        case .running:                 return "running"
        case .waitingInput,
             .waitingApproval:         return "waiting"
        case .completed:               return "jumping"
        case .failed:                  return "failed"
        }
    }

    /// Whether the state's animation is a one-shot that settles afterwards.
    ///
    /// A finished task and a failed one are both news; once delivered, the pet
    /// should stop repeating it.
    var animationPlaysOnce: Bool {
        self == .completed || self == .failed
    }

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
        // A finished turn is news, not a condition. Claude Code fires `Stop`
        // at the end of every turn, so without this the activity list would
        // read "completed" forever for every session that had ever answered.
        case .completed:        return 4
        case .waitingInput:     return nil
        case .idle:             return nil
        case .paused:           return nil
        }
    }

    /// The state this one degrades to after `staleTimeout` elapses.
    var staleSuccessor: AgentState? {
        switch self {
        case .running:          return .unknown
        case .unknown:          return .idle
        case .waitingApproval:  return .unknown
        case .failed:           return .idle
        case .completed:        return .idle
        case .waitingInput, .idle, .paused: return nil
        }
    }
}
