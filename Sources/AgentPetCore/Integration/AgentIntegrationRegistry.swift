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
    /// Kept current as the agents' own surfaces move: the 2026-09-15 audit
    /// (docs/ARCHITECTURE.md §6.7b) found Grok and Pi wireable and Codex
    /// gated only by its one-time trust step, so the notes say what is
    /// actually missing now rather than what once was. Shown on the card and
    /// by `--configure`.
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

    /// Grok's hooks are JSON files under `~/.grok/hooks/` (its config.toml
    /// can carry `[[hooks.<Event>]]` as an alternative), and its hook payload
    /// is camelCase where Claude's is snake_case. Wiring is possible but not
    /// built; see docs/ARCHITECTURE.md §6.7b.
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
            configurationNote: "Grok's hooks are JSON files in ~/.grok/hooks, so wiring is "
                + "possible; only its status line needs a TOML edit. Detected, not configured yet."
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

    /// Pi is extended by a single TypeScript file in
    /// `~/.pi/agent/extensions/`, so wiring would be a file drop rather than
    /// a package install. Not built yet; see docs/ARCHITECTURE.md §6.7b.
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
            configurationNote: "Pi is extended by one TypeScript file in ~/.pi/agent/extensions, "
                + "so wiring is a file drop rather than a package install. Detected, not configured yet."
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
