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
    /// Kept current as the agents' own surfaces move: updated 2026-09-15 when
    /// Grok and Pi were wired (docs/ARCHITECTURE.md §6.7b), leaving Codex the
    /// one agent whose note still has to explain itself. Shown on the card
    /// and by `--configure`.
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

    /// Grok's hooks live in `~/.grok/hooks/` as JSON (its config.toml can
    /// carry `[[hooks.<Event>]]` as an alternative). The configurator writes
    /// one dedicated file there and flips Grok's Claude-compat scan off in
    /// `config.toml`, so Grok is the only source of its own events; see
    /// docs/ARCHITECTURE.md §6.7b.
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
            configurator: GrokConfigurator(transaction: transaction),
            capabilities: [.detect, .configure, .uninstall, .liveEvents, .testEvent]
        )
    }

    /// Codex's hooks are stable and live in `~/.codex/hooks.json` as
    /// Claude-shaped JSON, but every non-managed entry must be reviewed and
    /// trusted by hand in its `/hooks` panel before it runs. Wiring is
    /// possible; the trust handshake is why there is no configurator yet.
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
            configurationNote: "Codex's hooks are stable JSON, but every entry must be "
                + "trusted by hand in Codex's /hooks panel before it runs. Detected, not configured yet."
        )
    }

    /// Pi is extended by one TypeScript file in `~/.pi/agent/extensions/`;
    /// the configurator writes exactly that file (node built-ins only, no
    /// package install, no settings edit) and deletes it on removal; see
    /// docs/ARCHITECTURE.md §6.7b.
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
            configurator: PiConfigurator(transaction: transaction),
            capabilities: [.detect, .configure, .uninstall, .liveEvents, .testEvent]
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
