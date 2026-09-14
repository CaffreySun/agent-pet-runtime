import CoreGraphics
import Foundation

/// How big the pet is drawn.
///
/// Codex's own setting is a slider over 80–224 px
/// (`avatar-overlay-mascot-width-px`, default 112), so the three sizes on
/// offer are its default and its two ends: every choice here is one Codex
/// itself allows, and the default is the size its own pet is drawn at.
public enum PetSize: String, Codable, Sendable, Equatable, CaseIterable, Identifiable {
    case small
    case standard
    case large

    /// The sprite's width in points. The atlas cell is 192×208, so the
    /// height follows from it.
    public var width: CGFloat {
        switch self {
        case .small:    return 80
        case .standard: return 112
        case .large:    return 224
        }
    }

    public var height: CGFloat { (width * 208 / 192).rounded() }

    public var displayName: String {
        switch self {
        case .small:    return "Small"
        case .standard: return "Default"
        case .large:    return "Large"
        }
    }

    public var id: String { rawValue }
}

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
    public var messagePanel: MessagePanelConfig

    public init(
        schemaVersion: Int = AppConfig.currentSchemaVersion,
        pet: PetConfig = PetConfig(),
        agents: AgentConfig = AgentConfig(),
        diagnostics: DiagnosticsConfig = DiagnosticsConfig(),
        messagePanel: MessagePanelConfig = MessagePanelConfig()
    ) {
        self.schemaVersion = schemaVersion
        self.pet = pet
        self.agents = agents
        self.diagnostics = diagnostics
        self.messagePanel = messagePanel
    }

    /// Decoded field by field, each with its default.
    ///
    /// Synthesised decoding would make every added setting a breaking change:
    /// a config file written by the previous version has no key for it, the
    /// decode fails, and `AppConfigStore.load()` — which refuses to half-read
    /// a file — would quietly reset the user's pet, window, and diagnostics
    /// choices. A missing key means "not chosen yet", which is exactly what
    /// the default is for.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppConfig()
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? defaults.schemaVersion
        pet = try container.decodeIfPresent(PetConfig.self, forKey: .pet) ?? defaults.pet
        agents = try container.decodeIfPresent(AgentConfig.self, forKey: .agents) ?? defaults.agents
        diagnostics = try container.decodeIfPresent(DiagnosticsConfig.self, forKey: .diagnostics)
            ?? defaults.diagnostics
        messagePanel = try container.decodeIfPresent(MessagePanelConfig.self, forKey: .messagePanel)
            ?? defaults.messagePanel
    }

    public struct PetConfig: Codable, Sendable, Equatable {
        /// The pet shown on the desktop. `nil` means "first one found".
        public var defaultPetID: String?
        public var animationEnabled: Bool
        public var alwaysOnTop: Bool
        /// Honours the system Reduce Motion setting when true.
        public var respectsReduceMotion: Bool
        /// How big the pet is drawn. `standard` is Codex's own size.
        public var size: PetSize

        public init(
            defaultPetID: String? = nil,
            animationEnabled: Bool = true,
            alwaysOnTop: Bool = true,
            respectsReduceMotion: Bool = true,
            size: PetSize = .standard
        ) {
            self.defaultPetID = defaultPetID
            self.animationEnabled = animationEnabled
            self.alwaysOnTop = alwaysOnTop
            self.respectsReduceMotion = respectsReduceMotion
            self.size = size
        }

        /// Decoded field by field, for the same reason `AppConfig` is: a config
        /// written before `size` existed has no key for it, and a synthesised
        /// decode would fail the whole nested object — taking the user's chosen
        /// pet down with the missing size.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let defaults = PetConfig()
            defaultPetID = try container.decodeIfPresent(String.self, forKey: .defaultPetID)
            animationEnabled = try container.decodeIfPresent(Bool.self, forKey: .animationEnabled)
                ?? defaults.animationEnabled
            alwaysOnTop = try container.decodeIfPresent(Bool.self, forKey: .alwaysOnTop)
                ?? defaults.alwaysOnTop
            respectsReduceMotion = try container.decodeIfPresent(Bool.self, forKey: .respectsReduceMotion)
                ?? defaults.respectsReduceMotion
            size = try container.decodeIfPresent(PetSize.self, forKey: .size) ?? defaults.size
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
