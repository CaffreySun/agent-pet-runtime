import Foundation

/// User-visible settings, persisted as JSON.
///
/// Kept in the core rather than UserDefaults so it can be validated, migrated,
/// and asserted on in tests.
public struct AppConfig: Codable, Sendable, Equatable {

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var pet: PetConfig
    public var agents: AgentConfig
    public var diagnostics: DiagnosticsConfig

    public init(
        schemaVersion: Int = AppConfig.currentSchemaVersion,
        pet: PetConfig = PetConfig(),
        agents: AgentConfig = AgentConfig(),
        diagnostics: DiagnosticsConfig = DiagnosticsConfig()
    ) {
        self.schemaVersion = schemaVersion
        self.pet = pet
        self.agents = agents
        self.diagnostics = diagnostics
    }

    public struct PetConfig: Codable, Sendable, Equatable {
        /// The pet shown on the desktop. `nil` means "first one found".
        public var defaultPetID: String?
        public var animationEnabled: Bool
        public var alwaysOnTop: Bool
        /// Honours the system Reduce Motion setting when true.
        public var respectsReduceMotion: Bool

        public init(
            defaultPetID: String? = nil,
            animationEnabled: Bool = true,
            alwaysOnTop: Bool = true,
            respectsReduceMotion: Bool = true
        ) {
            self.defaultPetID = defaultPetID
            self.animationEnabled = animationEnabled
            self.alwaysOnTop = alwaysOnTop
            self.respectsReduceMotion = respectsReduceMotion
        }
    }

    public struct AgentConfig: Codable, Sendable, Equatable {
        public var enabledAgents: [String]
        /// Off by default. Software that silently edits agent configuration on
        /// first sight is software the user cannot trust.
        public var autoConfigureNewAgents: Bool

        public init(enabledAgents: [String] = [], autoConfigureNewAgents: Bool = false) {
            self.enabledAgents = enabledAgents
            self.autoConfigureNewAgents = autoConfigureNewAgents
        }
    }

    public struct DiagnosticsConfig: Codable, Sendable, Equatable {
        public var loggingEnabled: Bool
        /// How many recent state transitions to keep for the diagnostics bundle.
        public var transitionHistoryLimit: Int

        public init(loggingEnabled: Bool = false, transitionHistoryLimit: Int = 200) {
            self.loggingEnabled = loggingEnabled
            self.transitionHistoryLimit = transitionHistoryLimit
        }
    }
}

/// Loads and saves `AppConfig`, tolerating a file that is missing or from a
/// future version.
public struct AppConfigStore: Sendable {

    public let url: URL

    public init(url: URL = BridgeSocketLocation.applicationSupportDirectory
        .appendingPathComponent("config.json")) {
        self.url = url
    }

    /// A config from an unknown future schema is ignored rather than partially
    /// applied: half-understanding a newer file is worse than defaults.
    public func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data),
              config.schemaVersion <= AppConfig.currentSchemaVersion
        else {
            return AppConfig()
        }
        return config
    }

    public func save(_ config: AppConfig) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
