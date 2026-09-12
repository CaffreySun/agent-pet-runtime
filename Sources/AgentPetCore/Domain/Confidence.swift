import Foundation

/// How much the runtime trusts an observed state.
///
/// A native hook reporting "waiting for approval" is fact. A process scan
/// inferring the same thing from a quiet terminal is a guess. The UI must be
/// able to tell these apart, so confidence travels with every event.
public enum ConfidenceLevel: String, Codable, Sendable, Comparable, CaseIterable {
    case low
    case medium
    case high

    private var rank: Int {
        switch self {
        case .low:    return 0
        case .medium: return 1
        case .high:   return 2
        }
    }

    public static func < (lhs: ConfidenceLevel, rhs: ConfidenceLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

public struct EventConfidence: Codable, Sendable, Equatable {
    public let level: ConfidenceLevel
    /// Human-readable provenance, e.g. `"claude-code.hook.PreToolUse"`.
    public let source: String

    public init(level: ConfidenceLevel, source: String) {
        self.level = level
        self.source = source
    }
}
