import Foundation

/// One hook entry the runtime wrote into an agent's configuration.
///
/// Recorded verbatim so removal matches on content rather than on a rule. If
/// the runtime is later moved to a different path, an old record still finds
/// the entries that were actually installed.
public struct WrittenEntry: Codable, Sendable, Equatable {
    public let file: String
    public let event: String
    public let command: String

    public init(file: String, event: String, command: String) {
        self.file = file
        self.event = event
        self.command = command
    }
}

/// What the runtime knows about its integration with one agent.
///
/// Never stores credentials, prompts, or model settings — only the fact that
/// certain hook lines exist and what they say.
public struct IntegrationRecord: Codable, Sendable, Equatable {
    public var agentID: String
    public var integrationVersion: Int
    public var status: IntegrationStatus
    public var configuredAt: Date?
    public var lastValidatedAt: Date?
    /// The shim path used at install time, kept even after the shim moves.
    public var shimPath: String?
    public var entries: [WrittenEntry]

    public static let currentIntegrationVersion = 1

    public init(
        agentID: String,
        integrationVersion: Int = IntegrationRecord.currentIntegrationVersion,
        status: IntegrationStatus = .notConfigured,
        configuredAt: Date? = nil,
        lastValidatedAt: Date? = nil,
        shimPath: String? = nil,
        entries: [WrittenEntry] = []
    ) {
        self.agentID = agentID
        self.integrationVersion = integrationVersion
        self.status = status
        self.configuredAt = configuredAt
        self.lastValidatedAt = lastValidatedAt
        self.shimPath = shimPath
        self.entries = entries
    }

    public var isConfigured: Bool { status == .configured && !entries.isEmpty }
}

/// The persisted half of an integration's state.
///
/// Deliberately excludes anything derived from reality. Whether the agent is
/// installed, and whether events are currently arriving, are recomputed every
/// time rather than cached — a stored `connected` flag would be wrong the
/// moment the agent quits.
public enum IntegrationStatus: String, Codable, Sendable, Equatable {
    case notConfigured
    case configured
    case configureFailed

    public var displayName: String {
        switch self {
        case .notConfigured:   return "Not Configured"
        case .configured:      return "Configured"
        case .configureFailed: return "Error"
        }
    }
}

/// What the UI shows, combining persisted state with what is true right now.
public enum IntegrationHealth: Sendable, Equatable {
    case notDetected
    case detected
    case connected
    case degraded
    /// Configured once, but our entries are no longer in the file.
    case disconnected
    case failed(String)

    public var displayName: String {
        switch self {
        case .notDetected:    return "Not Detected"
        case .detected:       return "Detected"
        case .connected:      return "Connected"
        case .degraded:       return "Degraded"
        case .disconnected:   return "Needs Attention"
        case .failed:         return "Error"
        }
    }

    public var isHealthy: Bool { self == .connected }
}

/// Derives display health. Kept separate from the stored record so it can be
/// recomputed on every menu refresh.
public struct IntegrationHealthEvaluator: Sendable {
    /// An event this recent means the pipeline is working end to end.
    public var freshnessWindow: TimeInterval

    public init(freshnessWindow: TimeInterval = 30) {
        self.freshnessWindow = freshnessWindow
    }

    public func health(
        record: IntegrationRecord,
        isDetected: Bool,
        lastEventAt: Date?,
        entriesPresent: Bool,
        now: Date,
        failure: String? = nil
    ) -> IntegrationHealth {
        if let failure { return .failed(failure) }
        if record.status == .configureFailed { return .failed("configuration error") }
        if !isDetected { return .notDetected }
        guard record.isConfigured else { return .detected }
        if !entriesPresent { return .disconnected }
        guard let lastEventAt else { return .degraded }
        return now.timeIntervalSince(lastEventAt) <= freshnessWindow ? .connected : .degraded
    }
}
