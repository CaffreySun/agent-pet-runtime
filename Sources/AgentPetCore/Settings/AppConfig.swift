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

        /// How big the pet is drawn, in points across.
        ///
        /// Codex's own setting is a slider over these bounds
        /// (`avatar-overlay-mascot-width-px`, default 112), so this is one too
        /// — the three named sizes it used to be were only ever its default
        /// and its two ends.
        public static let minimumWidth: Double = 80
        public static let maximumWidth: Double = 224
        public static let defaultWidth: Double = 112

        public static func clampWidth(_ points: Double) -> Double {
            min(max(points, minimumWidth), maximumWidth)
        }

        /// The height that width draws at: the atlas cell's own aspect ratio,
        /// as Codex's `calc(var(--codex-pet-width) * 208 / 192)`.
        public static func height(forWidth width: Double) -> Double {
            (width * 208 / 192).rounded()
        }

        /// The pet shown on the desktop. `nil` means "first one found".
        public var defaultPetID: String?
        public var animationEnabled: Bool
        public var alwaysOnTop: Bool
        /// Honours the system Reduce Motion setting when true.
        public var respectsReduceMotion: Bool
        /// How big the pet is drawn, 80–224 points across.
        public var width: Double
        /// Whether the pet is on screen. Codex calls putting it away "tuck
        /// away"; the app stays in the menu bar either way.
        public var visible: Bool

        public init(
            defaultPetID: String? = nil,
            animationEnabled: Bool = true,
            alwaysOnTop: Bool = true,
            respectsReduceMotion: Bool = true,
            width: Double = PetConfig.defaultWidth,
            visible: Bool = true
        ) {
            self.defaultPetID = defaultPetID
            self.animationEnabled = animationEnabled
            self.alwaysOnTop = alwaysOnTop
            self.respectsReduceMotion = respectsReduceMotion
            self.width = Self.clampWidth(width)
            self.visible = visible
        }

        /// The widths the three named sizes stood for, for a config written
        /// before this setting was a slider.
        private static let legacyWidths: [String: Double] = [
            "small": minimumWidth, "standard": defaultWidth, "large": maximumWidth,
        ]

        private enum CodingKeys: String, CodingKey {
            case defaultPetID, animationEnabled, alwaysOnTop, respectsReduceMotion
            case visible, width
        }

        /// The named size this setting used before it was a slider. Read
        /// through a key type of its own, because a synthesised encoder
        /// refuses to build when a coding key has no stored property behind it
        /// — and nothing should ever write `size` again.
        private enum LegacyKeys: String, CodingKey {
            case size
        }

        /// Decoded field by field, for the same reason `AppConfig` is: a config
        /// written before `width` existed has no key for it, and a synthesised
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
            if let points = try container.decodeIfPresent(Double.self, forKey: .width) {
                width = Self.clampWidth(points)
            } else if let named = try decoder.container(keyedBy: LegacyKeys.self)
                        .decodeIfPresent(String.self, forKey: .size),
                      let legacy = Self.legacyWidths[named] {
                width = legacy
            } else {
                width = defaults.width
            }
            visible = try container.decodeIfPresent(Bool.self, forKey: .visible) ?? defaults.visible
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
