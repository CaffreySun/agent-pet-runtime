import Foundation

/// Installs the Antigravity integration: one named hook in the CLI's
/// `hooks.json`.
///
/// The schema is the CLI's own and it is not uniform — tool events are wrapped
/// in `matcher` groups, while `SessionStart`, `PreInvocation`,
/// `PostInvocation`, `Stop`, and `SessionEnd` take flat handler lists (read out
/// of the installed 1.2.3 binary and confirmed on the wire, 2026-09-15). The
/// runtime owns exactly one named hook, `agentpet`; other named hooks —
/// plugins' or the user's — are preserved untouched, and removal takes only
/// ours, and only while it is still exactly what we wrote.
///
/// **`PreToolUse` is deliberately not registered.** Its stdout contract makes
/// `decision` *required* — `allow`, `deny`, `ask`, `force_ask`, and nothing
/// else — so there is no way for an observing hook to abstain. The shim
/// answers `{}` to every Antigravity event (its one exception to "never write
/// to stdout"), and a decision-less result is read as a denial: every tool
/// call dies with `tool call denied by pre-tool hook:` and an empty reason.
/// Reproduced against 1.1.14 by way of a probe hook that only printed `{}`
/// (crossby#147), reported by other projects (ai-memory#352), and reported
/// against 1.2.x here — on the CLI and the GUI both, since hooks.json is
/// shared between them. `PostToolUse` stays: its contract is an empty object,
/// it gates nothing, and it never fired in any captured turn either.
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
    public static let groupedEvents = ["PostToolUse"]

    public static let events = [
        "SessionStart", "PreInvocation", "PostInvocation",
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
        guard let present = commandsUnderOurName(),
              Self.recordedCommandsPresent(record, in: present)
        else { return false }
        // Recorded entries must still be there, and our named hook must not
        // hold an event this version stopped writing: that is the shape a
        // config left behind by an older launch has, and an obsolete event is
        // not an inert leftover — a decision-less `PreToolUse` result denies
        // every tool call. Reported as drift so the card can say so when the
        // automatic removal (see `removeObsoleteEntries`) cannot act.
        return Set(present.keys).isSubset(of: Set(Self.events))
    }

    /// Commands currently under our named hook, by event — or nil when there is
    /// no file, no readable one, or no named hook in it.
    private func commandsUnderOurName() -> [String: [String]]? {
        guard let data = try? Data(contentsOf: hooksURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let named = root[Self.hookName]
        else { return nil }
        return Self.commands(in: named)
    }

    /// Whether every command the record lists is still there. Says nothing
    /// about extra events: that is what separates "the user edited in here"
    /// from "an older version left a line behind".
    private static func recordedCommandsPresent(
        _ record: IntegrationRecord,
        in present: [String: [String]]
    ) -> Bool {
        record.entries.allSatisfy { present[$0.event]?.contains($0.command) == true }
    }

    // MARK: - Migration

    /// Drops hook lines an earlier version wrote that this one no longer
    /// installs — in practice, `PreToolUse`, which gated every tool call once
    /// Antigravity tightened its contract.
    ///
    /// Deliberately narrower than `configure`: it removes the recorded lines
    /// and nothing else. It does not re-point the shim, so a development build
    /// started next to an installed one cannot take the install's hooks over,
    /// and it refuses entirely when the named hook no longer holds exactly what
    /// was recorded — an edit in there is the user's, and the card's drift
    /// report is the honest answer for that case.
    public func removeObsoleteEntries(
        _ record: IntegrationRecord,
        now: Date
    ) throws -> ConfigurationOutcome? {
        let obsolete = record.entries.filter { !Self.events.contains($0.event) }
        guard !obsolete.isEmpty, let present = commandsUnderOurName(),
              Self.recordedCommandsPresent(record, in: present),
              // Everything else under our name has to be either an event we
              // write today or one of the obsolete ones this record recorded.
              Set(present.keys).isSubset(of: Set(Self.events).union(obsolete.map(\.event)))
        else { return nil }

        let obsoleteCommands = Set(obsolete.map(\.command))
        let outcome = try transaction.perform(on: hooksURL) { object in
            guard var named = object[Self.hookName] as? [String: Any] else { return }
            for event in Set(obsolete.map(\.event)) {
                guard var handlers = named[event] as? [[String: Any]] else { continue }
                handlers = handlers.compactMap { entry in
                    var entry = entry
                    var inner = entry["hooks"] as? [[String: Any]] ?? []
                    let original = inner
                    inner.removeAll { obsoleteCommands.contains($0["command"] as? String ?? "") }
                    // A flat event holds the handler itself; a grouped one holds
                    // the matcher wrapper, which goes when its inner list empties.
                    if !original.isEmpty {
                        if inner.isEmpty { return nil }
                        entry["hooks"] = inner
                        return entry
                    }
                    return obsoleteCommands.contains(entry["command"] as? String ?? "") ? nil : entry
                }
                if handlers.isEmpty {
                    named.removeValue(forKey: event)
                } else {
                    named[event] = handlers
                }
            }
            if named.isEmpty {
                object.removeValue(forKey: Self.hookName)
            } else {
                object[Self.hookName] = named
            }
        }

        // Nothing to write means nothing was found — a record that lists an
        // entry the file does not hold is drift, and reporting it as migrated
        // would hide exactly the case the card needs to show.
        guard outcome.didChange else { return nil }

        let updated = IntegrationRecord(
            agentID: agentID,
            status: .configured,
            configuredAt: record.configuredAt,
            lastValidatedAt: now,
            lastEventAt: record.lastEventAt,
            shimPath: record.shimPath,
            entries: record.entries.filter { Self.events.contains($0.event) }
        )
        return ConfigurationOutcome(
            record: updated,
            changedFiles: [hooksURL.path],
            backupURLs: outcome.backupURL.map { [$0.path] } ?? []
        )
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
