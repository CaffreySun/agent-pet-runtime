import Foundation

/// The known agents, and how each one is detected and configured.
///
/// One entry per agent. Adding an agent means adding a case here; nothing in
/// the activity engine, renderer, or bridge changes.
public struct AgentIntegrationProfile: Sendable {
    public let agentID: String
    public let displayName: String
    public let detection: AgentDetector.Specification
    /// `nil` when the agent has no configuration surface we can safely write.
    /// The UI shows it as detectable but not configurable.
    public let configurator: (any AgentConfigurator)?
    public let capabilities: Set<IntegrationCapability>
    /// Why there is no configurator, in the words that fit this agent.
    ///
    /// One shared sentence was a lie for two of the three: Grok's hooks are
    /// TOML, which the JSON transaction really cannot edit, while Codex's
    /// `notify` is an argv array and Pi is extended by installing a package —
    /// neither is a *format* problem. Shown on the card and by `--configure`.
    public let configurationNote: String?

    public init(
        agentID: String,
        displayName: String,
        detection: AgentDetector.Specification,
        configurator: (any AgentConfigurator)?,
        capabilities: Set<IntegrationCapability>,
        configurationNote: String? = nil
    ) {
        self.agentID = agentID
        self.displayName = displayName
        self.detection = detection
        self.configurator = configurator
        self.capabilities = capabilities
        self.configurationNote = configurationNote
    }
}

public enum IntegrationCapability: String, Codable, Sendable, CaseIterable {
    case detect
    case configure
    case uninstall
    case liveEvents
    case testEvent
    /// v0.1 cannot reliably raise another app's window; see docs/SPEC-REVIEW.md §3.3.
    case focusSession
}

public enum AgentIntegrationRegistry {

    public static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Claude Code reads hooks from its user settings file. Its hook payloads
    /// carry session id and cwd, so events correlate properly.
    public static func claudeCode(transaction: ConfigTransaction) -> AgentIntegrationProfile {
        let settings = home().appendingPathComponent(".claude/settings.json")
        return AgentIntegrationProfile(
            agentID: "claude-code",
            displayName: "Claude Code",
            detection: .init(
                agentID: "claude-code",
                displayName: "Claude Code",
                executableNames: ["claude"],
                extraSearchPaths: [home().appendingPathComponent(".local/bin")],
                configFiles: [settings]
            ),
            configurator: JSONHookConfigurator(
                agentID: "claude-code",
                configURL: settings,
                events: HookSetup.claudeCodeEvents,
                transaction: transaction
            ),
            capabilities: [.detect, .configure, .uninstall, .liveEvents, .testEvent]
        )
    }

    /// Grok documents its hook schema as matching Claude Code's, and reads
    /// `[[hooks.<Event>]]` from its own config. The events Grok fires are not
    /// documented as exhaustively, so the same set is installed and unlisted
    /// ones are simply ignored by the normalizer.
    public static func grok(transaction: ConfigTransaction) -> AgentIntegrationProfile {
        let config = home().appendingPathComponent(".grok/config.toml")
        return AgentIntegrationProfile(
            agentID: "grok",
            displayName: "Grok",
            detection: .init(
                agentID: "grok",
                displayName: "Grok",
                executableNames: ["grok"],
                configFiles: [config]
            ),
            // Grok's hooks live in TOML, which the JSON transaction cannot
            // edit safely. Reported as detected but not configurable rather
            // than half-supported.
            configurator: nil,
            capabilities: [.detect],
            configurationNote: "Grok's hooks live in TOML, which the JSON transaction cannot "
                + "edit safely. Detected, and left alone rather than half-supported."
        )
    }

    /// Codex has a `notify` setting but it is a single argv array, not a hook
    /// table, so installing into it needs its own configurator.
    public static func codex(transaction: ConfigTransaction) -> AgentIntegrationProfile {
        let config = home().appendingPathComponent(".codex/config.toml")
        return AgentIntegrationProfile(
            agentID: "codex",
            displayName: "Codex",
            detection: .init(
                agentID: "codex",
                displayName: "Codex",
                executableNames: ["codex"],
                configFiles: [config]
            ),
            configurator: nil,
            capabilities: [.detect],
            configurationNote: "Codex's notify hook is a single argv array rather than a hook "
                + "table, so installing into it needs a configurator of its own. "
                + "Detected, not configurable yet."
        )
    }

    /// Pi is extended by installing an npm/git package, which is a heavier
    /// operation than editing a config file.
    public static func pi(transaction: ConfigTransaction) -> AgentIntegrationProfile {
        AgentIntegrationProfile(
            agentID: "pi",
            displayName: "Pi",
            detection: .init(
                agentID: "pi",
                displayName: "Pi",
                executableNames: ["pi"],
                configFiles: [home().appendingPathComponent(".pi/agent/settings.json")]
            ),
            configurator: nil,
            capabilities: [.detect],
            configurationNote: "Pi is extended by installing a package, which is a heavier "
                + "operation than editing a config file. Detected, not configurable yet."
        )
    }

    public static func all(transaction: ConfigTransaction) -> [AgentIntegrationProfile] {
        [
            claudeCode(transaction: transaction),
            grok(transaction: transaction),
            codex(transaction: transaction),
            pi(transaction: transaction),
        ]
    }

    public static func profile(
        for agentID: String,
        transaction: ConfigTransaction
    ) -> AgentIntegrationProfile? {
        all(transaction: transaction).first { $0.agentID == agentID }
    }
}
