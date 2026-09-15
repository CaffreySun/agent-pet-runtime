import Foundation

/// Installs the Grok integration: a hooks file the runtime owns outright, plus
/// one switch that stops Grok's Claude-compatibility scan from re-firing the
/// Claude hooks as a second source for the same events.
///
/// Grok scans `~/.claude/settings.json` by default — verified on 1.0.24 by
/// capturing what the shim delivers — so without the switch every Grok event
/// would reach the pet twice. The switch is a `[compat.claude]` table with
/// `hooks = false` appended to `~/.grok/config.toml`: appended only, removed
/// byte for byte on uninstall, and a `[compat.claude]` table the user already
/// wrote is refused rather than edited.
public struct GrokConfigurator: AgentConfigurator {

    public let agentID = "grok"

    /// Every event the Grok profile has a rule for, and only those: an
    /// installed event with no rule would be a hook that exists to be
    /// ignored. `TaskCompleted` is Claude Code's; Grok never fires it.
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
        "PostToolUseFailure", "Stop", "StopFailure", "StopCancelled",
        "Notification", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact", "SessionEnd",
    ]

    public static let compatSwitch = TOMLBlock(
        header: "[compat.claude]",
        lines: ["hooks = false"],
        comments: [
            "# Written by Agent Pet Runtime: its hooks already reach the pet",
            "# directly, and this scan would fire them a second time.",
        ]
    )

    /// Record entry id for the appended TOML block.
    public static let compatEntryEvent = "compat.claude.hooks"

    public let hooksURL: URL
    public let configURL: URL

    private let transaction: ConfigTransaction
    private let hooks: JSONHookConfigurator

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        transaction: ConfigTransaction
    ) {
        self.hooksURL = home.appendingPathComponent(".grok/hooks/agentpet.json")
        self.configURL = home.appendingPathComponent(".grok/config.toml")
        self.transaction = transaction
        self.hooks = JSONHookConfigurator(
            agentID: "grok",
            configURL: hooksURL,
            events: Self.events,
            transaction: transaction
        )
    }

    // MARK: - Targets

    public func configurationTargets() -> [URL] { [hooksURL, configURL] }

    /// The record's hook-file entries — everything that is not the TOML block.
    private func hookEntries(in record: IntegrationRecord) -> [WrittenEntry] {
        record.entries.filter { $0.file != configURL.path }
    }

    private func compatEntry(in record: IntegrationRecord) -> WrittenEntry? {
        record.entries.first {
            $0.file == configURL.path && $0.event == Self.compatEntryEvent
        }
    }

    public func entriesPresent(in record: IntegrationRecord) -> Bool {
        var hookRecord = record
        hookRecord.entries = hookEntries(in: record)
        guard hooks.entriesPresent(in: hookRecord) else { return false }

        guard let entry = compatEntry(in: record),
              let text = try? String(contentsOf: configURL, encoding: .utf8)
        else { return false }
        return text.contains(entry.command)
    }

    // MARK: - Configure

    public func configure(
        shimPath: String,
        replacing previous: IntegrationRecord?,
        now: Date
    ) throws -> ConfigurationOutcome {

        // The hooks file goes first. If the switch landed without it, nothing
        // would reach the pet at all; the other order at least keeps a working
        // source until the second step succeeds.
        let hooksOutcome = try hooks.configure(
            shimPath: shimPath, replacing: previous, now: now
        )

        let switchOutcome: (added: String, backup: URL?, changed: Bool)
        do {
            switchOutcome = try installCompatSwitch(
                previous: previous.flatMap { compatEntry(in: $0)?.command }
            )
        } catch {
            // Undo this call's own writes: a half-installed Grok would fire
            // every event twice, once from each source. A no-op JSON step —
            // a refused reconfigure — left a working hooks file alone, and it
            // stays that way.
            if hooksOutcome.didChange {
                _ = try? hooks.uninstall(hooksOutcome.record, now: now)
            }
            if case TOMLEditError.sectionExists(let section) = error {
                throw ConfigurationError.transactionFailed(
                    "\(configURL.path) already defines [\(section)], and the runtime will not "
                        + "edit a table it did not write. Set `hooks = false` there yourself, "
                        + "then configure Grok again."
                )
            }
            throw error
        }

        var entries = hookEntries(in: hooksOutcome.record)
        entries.append(WrittenEntry(
            file: configURL.path,
            event: Self.compatEntryEvent,
            command: switchOutcome.added
        ))

        let record = IntegrationRecord(
            agentID: agentID,
            status: .configured,
            configuredAt: previous?.configuredAt ?? now,
            lastValidatedAt: now,
            shimPath: shimPath,
            entries: entries
        )

        var changed = hooksOutcome.changedFiles
        if switchOutcome.changed { changed.append(configURL.path) }
        var backups = hooksOutcome.backupURLs
        if let backup = switchOutcome.backup { backups.append(backup.path) }

        return ConfigurationOutcome(record: record, changedFiles: changed, backupURLs: backups)
    }

    /// Ensures the `[compat.claude]` switch is in place, appended and recorded
    /// byte for byte. Idempotent: a switch we recorded before is left alone,
    /// and so is the canonical block if a first run finds it already there.
    private func installCompatSwitch(
        previous: String?
    ) throws -> (added: String, backup: URL?, changed: Bool) {
        var added = previous ?? ""
        var backupURL: URL?

        let outcome = try transaction.performText(
            on: configURL,
            transform: { text in
                if let previous, text.contains(previous) { return }

                if text.contains(Self.compatSwitch.text) {
                    added = Self.compatSwitch.text
                    return
                }

                let appended = try TOMLSectionEdit.appended(Self.compatSwitch, to: text)
                added = appended.added
                text = appended.result
            },
            verify: { text in
                text.contains(Self.compatSwitch.text)
                    || previous.map(text.contains) == true
                    || !added.isEmpty && text.contains(added)
            }
        )
        backupURL = outcome.backupURL

        if !outcome.didChange, added.isEmpty {
            added = Self.compatSwitch.text
        }
        return (added, backupURL, outcome.didChange)
    }

    // MARK: - Uninstall

    public func uninstall(
        _ record: IntegrationRecord,
        now: Date
    ) throws -> ConfigurationOutcome {

        // The hooks file goes first, then the switch: restoring the compat
        // scan while our file is still installed would double every event
        // during the gap.
        var hookRecord = record
        hookRecord.entries = hookEntries(in: record)
        let hooksOutcome = try hooks.uninstall(hookRecord, now: now)

        var changed = hooksOutcome.changedFiles
        var backups = hooksOutcome.backupURLs

        if let entry = compatEntry(in: record) {
            let added = entry.command
            let outcome = try transaction.performText(
                on: configURL,
                transform: { text in
                    // Only take back what is still ours; a user edit is theirs.
                    if text.contains(added) {
                        text = try TOMLSectionEdit.removing(added, from: text)
                    }
                },
                verify: { !$0.contains(added) }
            )
            if outcome.didChange { changed.append(configURL.path) }
            if let backup = outcome.backupURL { backups.append(backup.path) }
        }

        let updated = IntegrationRecord(
            agentID: agentID,
            status: .notConfigured,
            configuredAt: record.configuredAt,
            lastValidatedAt: now,
            shimPath: record.shimPath,
            entries: []
        )
        return ConfigurationOutcome(record: updated, changedFiles: changed, backupURLs: backups)
    }
}
