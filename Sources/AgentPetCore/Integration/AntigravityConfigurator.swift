import Foundation

/// Installs the Antigravity integration: one named hook in the CLI's
/// `hooks.json`.
///
/// The schema is the CLI's own and it is not uniform — `PreToolUse` and
/// `PostToolUse` handlers are wrapped in `matcher` groups, while
/// `SessionStart`, `PreInvocation`, `PostInvocation`, `Stop`, and `SessionEnd`
/// take flat handler lists (read out of the installed 1.2.3 binary and
/// confirmed on the wire, 2026-09-15). The runtime owns exactly one named
/// hook, `agentpet`; other named hooks — plugins' or the user's — are
/// preserved untouched, and removal takes only ours, and only while it is
/// still exactly what we wrote.
public struct AntigravityConfigurator: AgentConfigurator {

    public let agentID = "antigravity"

    /// The hook name the runtime owns inside hooks.json.
    public static let hookName = "agentpet"

    /// Flat events: a bare list of handler objects.
    public static let flatEvents = [
        "SessionStart", "PreInvocation", "PostInvocation", "Stop", "SessionEnd",
    ]

    /// Grouped events: `matcher`-wrapped handler groups. `PostToolUse` is
    /// registered although no captured turn ever fired it; the registration
    /// is inert if that stays true, and nothing depends on it.
    public static let groupedEvents = ["PreToolUse", "PostToolUse"]

    public static let events = [
        "SessionStart", "PreInvocation", "PostInvocation", "PreToolUse",
        "PostToolUse", "Stop", "SessionEnd",
    ]

    public let hooksURL: URL
    private let transaction: ConfigTransaction

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        transaction: ConfigTransaction
    ) {
        self.hooksURL = home.appendingPathComponent(".gemini/config/hooks.json")
        self.transaction = transaction
    }

    public func configurationTargets() -> [URL] { [hooksURL] }

    // MARK: - Commands

    public static func command(shimPath: String, event: String) -> String {
        "\(HookSetup.shellQuoted(shimPath)) --agent antigravity --event \(event)"
    }

    static func handler(shimPath: String, event: String) -> [String: Any] {
        [
            "type": "command",
            "command": command(shimPath: shimPath, event: event),
            "timeout": 5,
        ]
    }

    static func configuration(shimPath: String) -> [String: Any] {
        var named: [String: Any] = [:]
        for event in flatEvents {
            named[event] = [handler(shimPath: shimPath, event: event)]
        }
        for event in groupedEvents {
            named[event] = [[
                "matcher": "*",
                "hooks": [handler(shimPath: shimPath, event: event)],
            ]]
        }
        return named
    }

    /// Every command under a named hook, whoever wrote it, in both shapes.
    static func commands(in named: Any) -> [String: [String]] {
        guard let events = named as? [String: Any] else { return [:] }
        var result: [String: [String]] = [:]
        for (event, value) in events {
            guard let handlers = value as? [[String: Any]] else { continue }
            var commands: [String] = []
            for entry in handlers {
                if let command = entry["command"] as? String {
                    commands.append(command)
                }
                for inner in entry["hooks"] as? [[String: Any]] ?? [] {
                    if let command = inner["command"] as? String {
                        commands.append(command)
                    }
                }
            }
            result[event] = commands
        }
        return result
    }

    // MARK: - Reading

    public func entriesPresent(in record: IntegrationRecord) -> Bool {
        guard let data = try? Data(contentsOf: hooksURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let named = root[Self.hookName]
        else { return false }
        let present = Self.commands(in: named)
        return record.entries.allSatisfy {
            present[$0.event]?.contains($0.command) == true
        }
    }

    // MARK: - Configure

    public func configure(
        shimPath: String,
        replacing previous: IntegrationRecord?,
        now: Date
    ) throws -> ConfigurationOutcome {

        let outcome = try transaction.perform(on: hooksURL) { object in
            // Ours is one named hook; everything else in the file is not ours
            // to touch, and replacing the whole value is what makes a moved
            // shim a re-point rather than a second entry.
            object[Self.hookName] = Self.configuration(shimPath: shimPath)
        }

        let entries = Self.events.map {
            WrittenEntry(
                file: hooksURL.path,
                event: $0,
                command: Self.command(shimPath: shimPath, event: $0)
            )
        }
        let record = IntegrationRecord(
            agentID: agentID,
            status: .configured,
            configuredAt: previous?.configuredAt ?? now,
            lastValidatedAt: now,
            shimPath: shimPath,
            entries: entries
        )
        return ConfigurationOutcome(
            record: record,
            changedFiles: outcome.didChange ? [hooksURL.path] : [],
            backupURLs: outcome.backupURL.map { [$0.path] } ?? []
        )
    }

    // MARK: - Uninstall

    public func uninstall(
        _ record: IntegrationRecord,
        now: Date
    ) throws -> ConfigurationOutcome {
        var removed = false

        let outcome = try transaction.perform(on: hooksURL) { object in
            guard let named = object[Self.hookName] else { return }
            // Only take the named hook back while it is still exactly ours;
            // an edit inside it is the user's.
            let present = Self.commands(in: named)
            guard record.entries.allSatisfy({
                present[$0.event]?.contains($0.command) == true
            }) else { return }
            object.removeValue(forKey: Self.hookName)
            removed = true
        }

        let updated = IntegrationRecord(
            agentID: agentID,
            status: .notConfigured,
            configuredAt: record.configuredAt,
            lastValidatedAt: now,
            shimPath: record.shimPath,
            entries: []
        )
        return ConfigurationOutcome(
            record: updated,
            changedFiles: removed ? [hooksURL.path] : [],
            backupURLs: outcome.backupURL.map { [$0.path] } ?? []
        )
    }
}
