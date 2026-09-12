import Foundation

/// A single state change, kept for the diagnostics bundle.
public struct StateTransition: Codable, Sendable, Equatable {
    public let at: Date
    public let agentID: String
    public let sessionID: String
    public let from: String?
    public let to: String
    public let confidence: String
    public let source: String

    public init(
        at: Date, agentID: String, sessionID: String,
        from: String?, to: String, confidence: String, source: String
    ) {
        self.at = at
        self.agentID = agentID
        self.sessionID = sessionID
        self.from = from
        self.to = to
        self.confidence = confidence
        self.source = source
    }
}

/// Records state changes for the exported bundle, bounded so a long-running
/// session cannot grow it without limit.
public final class TransitionLog: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [StateTransition] = []
    private var lastState: [SessionKey: String] = [:]
    public let limit: Int

    public init(limit: Int = 200) {
        self.limit = limit
    }

    public func record(_ activity: AgentActivity) {
        let key = SessionKey(agentID: activity.agentID, sessionID: activity.sessionID)

        lock.lock()
        defer { lock.unlock() }

        let previous = lastState[key]

        // Only transitions are interesting. Repeated `working` events are
        // noise that would crowd out everything else in a bounded buffer.
        guard previous != activity.state.rawValue else { return }
        lastState[key] = activity.state.rawValue

        storage.append(StateTransition(
            at: activity.updatedAt,
            agentID: activity.agentID,
            sessionID: activity.sessionID,
            from: previous,
            to: activity.state.rawValue,
            confidence: activity.confidence.level.rawValue,
            source: activity.confidence.source
        ))
        if storage.count > limit {
            storage.removeFirst(storage.count - limit)
        }
    }

    public func forget(sessionKey: SessionKey) {
        lock.lock(); defer { lock.unlock() }
        lastState.removeValue(forKey: sessionKey)
    }

    public var transitions: [StateTransition] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

/// Everything a bug report needs, and nothing the user would not want to send.
///
/// The design lists what must not be here: prompts, model output, API keys,
/// OAuth tokens, and source code. Nothing in this type touches any of them —
/// the runtime never reads them in the first place.
public struct DiagnosticsBundle: Codable, Sendable {

    public struct AppInfo: Codable, Sendable {
        public let version: String
        public let macOSVersion: String
        public let architecture: String
    }

    public struct PetSummary: Codable, Sendable {
        public let id: String
        public let displayName: String
        public let profile: String
        public let compatibilityWarningCount: Int

        public init(id: String, displayName: String, profile: String, compatibilityWarningCount: Int) {
            self.id = id
            self.displayName = displayName
            self.profile = profile
            self.compatibilityWarningCount = compatibilityWarningCount
        }
    }

    public struct AgentSummary: Codable, Sendable {
        public let agentID: String
        public let detected: Bool
        public let executablePath: String?
        public let version: String?
        public let integrationStatus: String
        public let health: String
        public let hookCount: Int
        public let lastEventAt: Date?

        public init(
            agentID: String, detected: Bool, executablePath: String?, version: String?,
            integrationStatus: String, health: String, hookCount: Int, lastEventAt: Date?
        ) {
            self.agentID = agentID
            self.detected = detected
            self.executablePath = executablePath
            self.version = version
            self.integrationStatus = integrationStatus
            self.health = health
            self.hookCount = hookCount
            self.lastEventAt = lastEventAt
        }
    }

    public struct BridgeSummary: Codable, Sendable {
        public let isListening: Bool
        public let socketPath: String
        public let eventsReceived: Int
        public let malformedFrames: Int

        public init(isListening: Bool, socketPath: String, eventsReceived: Int, malformedFrames: Int) {
            self.isListening = isListening
            self.socketPath = socketPath
            self.eventsReceived = eventsReceived
            self.malformedFrames = malformedFrames
        }
    }

    public let generatedAt: Date
    public let app: AppInfo
    public let bridge: BridgeSummary
    public let pets: [PetSummary]
    public let agents: [AgentSummary]
    public let transitions: [StateTransition]

    public init(
        app: AppInfo,
        bridge: BridgeSummary,
        pets: [PetSummary],
        agents: [AgentSummary],
        transitions: [StateTransition],
        generatedAt: Date = Date()
    ) {
        self.generatedAt = generatedAt
        self.app = app
        self.bridge = bridge
        self.pets = pets
        self.agents = agents
        self.transitions = transitions
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func currentAppInfo() -> AppInfo {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "0.1.0-dev"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return AppInfo(
            version: version,
            macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            architecture: currentArchitecture()
        )
    }

    static func currentArchitecture() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw -> String in
            let bytes = raw.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
        return machine.isEmpty ? "unknown" : machine
    }
}
