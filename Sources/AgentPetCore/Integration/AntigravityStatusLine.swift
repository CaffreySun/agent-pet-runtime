import Foundation

/// Reads model, context, and cost from Antigravity's status line — the one
/// place its CLI reports them.
///
/// Unlike Grok's tap this one renders: Antigravity's default status row is
/// visible, and a command replaces it rather than wrapping it, so the shim
/// prints a plain replacement row (`dir │ model │ N% ctx`) and the terminal
/// keeps a status line instead of losing one. The row is the only thing the
/// shim prints there; the numbers themselves go to the pet.
///
/// The section is a shared settings key, so the runtime refuses to touch one
/// it did not write, and uninstall restores the previous value byte for byte
/// (or removes the key when there was nothing before us).
public struct AntigravityStatusLine: Sendable {

    /// Record file name. Distinct from `antigravity`: the hooks and the tap
    /// are installed and removed independently.
    public static let recordID = "antigravity-statusline"
    public static let blockEvent = "statusLine"
    public static let originalEvent = "statusLine.original"

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
    ) -> AntigravityStatusLine {
        AntigravityStatusLine(
            configURL: home.appendingPathComponent(".gemini/antigravity-cli/settings.json"),
            store: store,
            transaction: transaction
        )
    }

    // MARK: - Commands

    /// The command written into `statusLine`. Guarded on the shim's own
    /// existence so a deleted app cannot paint an error into the row.
    public static func command(shimPath: String) -> String {
        let quoted = HookSetup.shellQuoted(shimPath)
        return "if [ -x \(quoted) ]; then \(quoted) --agent antigravity --statusline --render-row; fi"
    }

    static func statusLineCommand(in value: Any?) -> String? {
        if let string = value as? String { return string }
        if let dictionary = value as? [String: Any] { return dictionary["command"] as? String }
        return nil
    }

    // MARK: - State

    public enum State: Equatable, Sendable {
        case notInstalled
        case installed
        case drifted
    }

    public func state() -> State {
        let record = store.record(for: Self.recordID)
        guard record.isConfigured,
              let wrapper = record.entries.first(where: { $0.event == Self.blockEvent })?.command
        else { return .notInstalled }
        guard Self.statusLineCommand(in: readRoot()["statusLine"]) == wrapper else {
            return .drifted
        }
        return .installed
    }

    // MARK: - Install

    @discardableResult
    public func configure(shimPath: String, now: Date = Date()) throws -> ConfigurationOutcome {
        var original: String?
        let wrapper = Self.command(shimPath: shimPath)

        let outcome = try transaction.perform(on: configURL) { object in
            let existing = object["statusLine"]
            let current = Self.statusLineCommand(in: existing)

            // Only replace ourselves, or the visible builtin default (which is
            // represented by absence). A command someone else wrote is theirs.
            if let current, current != wrapper {
                throw ConfigurationError.transactionFailed(
                    "\(configURL.path) already defines a status line, and the runtime will "
                        + "not replace one it did not write. Run `/statusline delete` inside "
                        + "Antigravity (or remove the `statusLine` key) and try again."
                )
            }

            if let existing {
                original = Self.serialize(existing)
            }
            object["statusLine"] = ["type": "command", "command": wrapper]
        }

        var entries = [WrittenEntry(file: configURL.path, event: Self.blockEvent, command: wrapper)]
        if let original {
            entries.append(WrittenEntry(file: configURL.path, event: Self.originalEvent, command: original))
        }
        let record = IntegrationRecord(
            agentID: Self.recordID,
            status: .configured,
            configuredAt: store.record(for: Self.recordID).configuredAt ?? now,
            lastValidatedAt: now,
            shimPath: shimPath,
            entries: entries
        )
        try store.save(record)

        return ConfigurationOutcome(
            record: record,
            changedFiles: outcome.didChange ? [configURL.path] : [],
            backupURLs: outcome.backupURL.map { [$0.path] } ?? []
        )
    }

    // MARK: - Uninstall

    @discardableResult
    public func uninstall(now: Date = Date()) throws -> ConfigurationOutcome {
        let record = store.record(for: Self.recordID)
        guard let wrapper = record.entries.first(where: { $0.event == Self.blockEvent })?.command
        else {
            return ConfigurationOutcome(record: record, changedFiles: [], backupURLs: [])
        }
        let original = record.entries.first { $0.event == Self.originalEvent }?.command
        var restored = false

        let outcome = try transaction.perform(on: configURL) { object in
            // Only take back what is still ours.
            guard Self.statusLineCommand(in: object["statusLine"]) == wrapper else { return }
            if let original, let value = Self.deserialize(original) {
                object["statusLine"] = value
            } else {
                // Nothing was there before us; leaving an empty section behind
                // would be residue we invented.
                object.removeValue(forKey: "statusLine")
            }
            restored = true
        }

        var cleared = record
        cleared.status = .notConfigured
        cleared.lastValidatedAt = now
        cleared.entries = []
        try store.save(cleared)

        return ConfigurationOutcome(
            record: cleared,
            changedFiles: restored ? [configURL.path] : [],
            backupURLs: outcome.backupURL.map { [$0.path] } ?? []
        )
    }

    // MARK: - Files

    private func readRoot() -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return root
    }

    static func serialize(_ value: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    static func deserialize(_ string: String) -> Any? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
}
