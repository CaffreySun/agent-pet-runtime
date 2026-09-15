import Foundation

/// Reads model, context, and cost from Grok's status line — the one place
/// Grok reports them.
///
/// Grok hands its status-line command a JSON payload with the session's model,
/// context-window usage, and cost: the same convention Claude Code uses, and
/// the runtime's shim reduces both with the same allowlist. Unlike the Claude
/// tap there is nothing to wrap — the row is off by default, and a command
/// there would be the user's own if they had set one. The command installed
/// here is the shim alone, and it prints nothing, so the row never appears and
/// the terminal looks exactly as it did before.
///
/// It is opt-in, and a separate record from the hook integration on purpose:
/// one record per concern, so removal and drift checks stay honest.
public struct GrokStatusLine: Sendable {

    /// Record file name. Distinct from `grok`: the hooks and the tap are
    /// installed and removed independently.
    public static let recordID = "grok-statusline"
    /// Record entry id for the appended `[ui.status_line]` block.
    public static let blockEvent = "ui.status_line"

    public let configURL: URL
    private let store: IntegrationStore
    private let transaction: ConfigTransaction

    public init(configURL: URL, store: IntegrationStore, transaction: ConfigTransaction) {
        self.configURL = configURL
        self.store = store
        self.transaction = transaction
    }

    public static func `default`(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        store: IntegrationStore,
        transaction: ConfigTransaction
    ) -> GrokStatusLine {
        GrokStatusLine(
            configURL: home.appendingPathComponent(".grok/config.toml"),
            store: store,
            transaction: transaction
        )
    }

    // MARK: - Blocks

    /// The command written into `[ui.status_line]`.
    ///
    /// Guarded on the shim's own existence: the app can be deleted while the
    /// config stays behind, and a command pointing at a missing path would
    /// paint an error into the user's terminal. Printing nothing keeps the
    /// row absent — the same look the disabled default has.
    public static func command(shimPath: String) -> String {
        let quoted = HookSetup.shellQuoted(shimPath)
        return "if [ -x \(quoted) ]; then \(quoted) --agent grok --statusline; fi"
    }

    public static func block(shimPath: String) -> TOMLBlock {
        TOMLBlock(
            header: "[ui.status_line]",
            lines: [
                "type = \"command\"",
                "command = \(tomlString(command(shimPath: shimPath)))",
            ],
            comments: [
                "# Written by Agent Pet Runtime: feeds session numbers to the pet.",
                "# The command prints nothing, so no status row appears.",
            ]
        )
    }

    /// A TOML basic-string literal for the command. The command is shell code
    /// with single-quoted paths, so a double quote or backslash is the only
    /// thing that needs escaping.
    static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    // MARK: - State

    public enum State: Equatable, Sendable {
        case notInstalled
        /// Our block is in the file, byte for byte.
        case installed
        /// It was installed, and something else has since had its way with
        /// the section.
        case drifted
    }

    public func state() -> State {
        let record = store.record(for: Self.recordID)
        guard record.isConfigured, let entry = recordedEntry(in: record) else { return .notInstalled }
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return .drifted }
        return text.contains(entry.command) ? .installed : .drifted
    }

    private func recordedEntry(in record: IntegrationRecord) -> WrittenEntry? {
        record.entries.first { $0.event == Self.blockEvent }
    }

    // MARK: - Install

    @discardableResult
    public func configure(shimPath: String, now: Date = Date()) throws -> ConfigurationOutcome {
        let block = Self.block(shimPath: shimPath)
        let previous = recordedEntry(in: store.record(for: Self.recordID))
        var added = ""
        var backupURL: URL?

        let outcome: TransactionOutcome
        do {
            outcome = try transaction.performText(
                on: configURL,
                transform: { text in
                    // Already ours, byte for byte.
                    if let previous, text.contains(previous.command) {
                        if previous.command == block.text {
                            added = previous.command
                            return
                        }
                        // The shim has moved: take the old block out and put
                        // the new one in, rather than nesting a second.
                        let stripped = try TOMLSectionEdit.removing(previous.command, from: text)
                        let appended = try TOMLSectionEdit.appended(block, to: stripped)
                        added = appended.added
                        text = appended.result
                        return
                    }
                    if text.contains(block.text) {
                        added = block.text
                        return
                    }
                    let appended = try TOMLSectionEdit.appended(block, to: text)
                    added = appended.added
                    text = appended.result
                },
                verify: { text in
                    text.contains(block.text)
                        || previous.map { text.contains($0.command) } == true
                }
            )
        } catch TOMLEditError.sectionExists(let section) {
            throw ConfigurationError.transactionFailed(
                "\(configURL.path) already defines [\(section)], and the runtime will not "
                    + "edit a table it did not write. Remove it (or run `/statusline delete` "
                    + "inside Grok) and try again."
            )
        }
        backupURL = outcome.backupURL

        let record = IntegrationRecord(
            agentID: Self.recordID,
            status: .configured,
            configuredAt: store.record(for: Self.recordID).configuredAt ?? now,
            lastValidatedAt: now,
            shimPath: shimPath,
            entries: [WrittenEntry(file: configURL.path, event: Self.blockEvent, command: added)]
        )
        try store.save(record)

        return ConfigurationOutcome(
            record: record,
            changedFiles: outcome.didChange ? [configURL.path] : [],
            backupURLs: backupURL.map { [$0.path] } ?? []
        )
    }

    @discardableResult
    public func uninstall(now: Date = Date()) throws -> ConfigurationOutcome {
        let record = store.record(for: Self.recordID)
        var removed = false
        var backupURL: URL?

        if let entry = recordedEntry(in: record) {
            let outcome = try transaction.performText(
                on: configURL,
                transform: { text in
                    // Only take back what is still ours.
                    if text.contains(entry.command) {
                        text = try TOMLSectionEdit.removing(entry.command, from: text)
                        removed = true
                    }
                },
                verify: { !$0.contains(entry.command) }
            )
            backupURL = outcome.backupURL
        }

        var cleared = record
        cleared.status = .notConfigured
        cleared.lastValidatedAt = now
        cleared.entries = []
        try store.save(cleared)

        return ConfigurationOutcome(
            record: cleared,
            changedFiles: removed ? [configURL.path] : [],
            backupURLs: backupURL.map { [$0.path] } ?? []
        )
    }
}
