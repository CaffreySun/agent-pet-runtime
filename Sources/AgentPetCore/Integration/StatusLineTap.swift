import Foundation

/// Reads context usage from Claude Code's status line — the only place it exists.
///
/// Hooks carry no token counts. Claude Code computes context usage for the
/// status-line command and hands it a JSON payload with
/// `context_window.used_percentage` already calculated, which matters because
/// only Claude Code knows the context window of the model actually in use —
/// behind a gateway that can be a model no outside observer has heard of.
///
/// So the tap wraps whatever status line the user already has: the runtime's
/// shim receives the JSON, forwards a reduced copy, and then runs the original
/// command *verbatim* with the same input and passes its output through
/// unchanged. The user's prompt keeps looking exactly as it did; when the tap
/// is removed, the original command is restored byte for byte.
///
/// It is opt-in, and the manager says what it does before it does it: this
/// edits `~/.claude/settings.json`'s `statusLine` key, and a setting that
/// changes what the user sees in every one of their terminals is not something
/// to install quietly.
public struct StatusLineTap: Sendable {

    /// Record file name. Distinct from `claude-code` on purpose: the hook
    /// integration and the tap are installed and removed independently, and
    /// one record per concern is what keeps `entriesPresent` honest.
    public static let recordID = "claude-code-statusline"

    /// What the shim does when the status line runs it.
    public static let modeFlag = "--statusline"
    /// Carries the original command, base64, so nothing in it can be
    /// re-parsed by a shell on the way back out.
    public static let originalFlag = "--original"

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
    ) -> StatusLineTap {
        StatusLineTap(
            configURL: home.appendingPathComponent(".claude/settings.json"),
            store: store,
            transaction: transaction
        )
    }

    // MARK: - State

    public enum State: Equatable, Sendable {
        case notInstalled
        /// Our wrapper is the status line, and it still wraps `original`.
        case installed(original: String?)
        /// It was installed, and something else has since had its way with
        /// the key — the user rewrote their status line, or another tool did.
        case drifted
    }

    public func state() -> State {
        let record = store.record(for: Self.recordID)
        guard record.isConfigured,
              let wrapper = record.entries.first(where: { $0.event == Self.wrapperEvent })?.command
        else { return .notInstalled }

        guard let current = Self.statusLineCommand(in: readRoot()["statusLine"]),
              current == wrapper
        else { return .drifted }
        return .installed(original: record.entries.first { $0.event == Self.originalEvent }?.command)
    }

    // MARK: - Install

    public static let wrapperEvent = "statusLine"
    /// The command we displaced, kept so removing the tap restores it. Stored
    /// as a second recorded entry because that is the one place an
    /// `IntegrationRecord` is allowed to keep a string.
    public static let originalEvent = "statusLine.original"

    @discardableResult
    public func configure(shimPath: String, now: Date = Date()) throws -> ConfigurationOutcome {
        var original: String?
        var wrapper = ""

        let outcome = try transaction.perform(on: configURL) { object in
            let existing = object["statusLine"]
            let current = Self.statusLineCommand(in: existing)
            // Unwrap if what is there is already ours: re-installing after the
            // app moved must replace our wrapper, not nest a second one
            // inside it.
            original = Self.originalCommand(wrappedIn: current) ?? current
            wrapper = Self.wrapperCommand(shimPath: shimPath, original: original)

            var replacement: [String: Any] = ["type": "command", "command": wrapper]
            // Everything else the user put in there — padding and whatever a
            // future version adds — stays.
            if var dictionary = existing as? [String: Any] {
                dictionary["command"] = wrapper
                if dictionary["type"] == nil { dictionary["type"] = "command" }
                replacement = dictionary
            }
            object["statusLine"] = replacement
        }

        var entries = [WrittenEntry(file: configURL.path, event: Self.wrapperEvent, command: wrapper)]
        if let original, !original.isEmpty {
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

    @discardableResult
    public func uninstall(now: Date = Date()) throws -> ConfigurationOutcome {
        let record = store.record(for: Self.recordID)
        guard let wrapper = record.entries.first(where: { $0.event == Self.wrapperEvent })?.command
        else {
            return ConfigurationOutcome(record: record, changedFiles: [], backupURLs: [])
        }
        let original = record.entries.first { $0.event == Self.originalEvent }?.command
        var restored = false

        let outcome = try transaction.perform(on: configURL) { object in
            // Only take back what is still ours. If the user has since written
            // their own status line, it is theirs, and the record is simply
            // stale — the same rule the hook configurator follows.
            guard Self.statusLineCommand(in: object["statusLine"]) == wrapper else { return }

            if let original, !original.isEmpty {
                if var dictionary = object["statusLine"] as? [String: Any] {
                    dictionary["command"] = original
                    object["statusLine"] = dictionary
                } else {
                    object["statusLine"] = ["type": "command", "command": original]
                }
            } else {
                // There was no status line before us; leaving an empty one
                // behind would be residue we invented.
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

    // MARK: - Commands

    /// The command written into `statusLine`.
    ///
    /// Wrapped in a guard on the shim's own existence, on its own lines: the
    /// day this app is deleted — `brew uninstall`, a dragged-to-the-trash
    /// bundle — the shim goes with it, and without the guard the user's shell
    /// would try to run a path that no longer exists and their status line
    /// would break. With it, their own command takes over as if the tap had
    /// never been there.
    ///
    /// The fallback sits on its own line rather than after a `;`, because a
    /// command ending in a `#` comment would otherwise swallow whatever
    /// followed it.
    public static func wrapperCommand(shimPath: String, original: String?) -> String {
        let quoted = HookSetup.shellQuoted(shimPath)
        let encoded = Data((original ?? "").utf8).base64EncodedString()
        let fallback = (original?.isEmpty == false) ? original! : ":"
        return """
        if [ -x \(quoted) ]; then
        \(quoted) --agent claude-code \(modeFlag) \(originalFlag) \(encoded)
        else
        \(fallback)
        fi
        """
    }

    /// The command `wrapper` wraps, or nil when `wrapper` is not one of ours.
    ///
    /// Recognised by the `--original` payload rather than by the shim path, so
    /// a wrapper installed by a previous version of the app — or from a
    /// different bundle location — is still recognised and unwrapped instead
    /// of being wrapped a second time.
    public static func originalCommand(wrappedIn wrapper: String?) -> String? {
        guard let wrapper,
              let range = wrapper.range(of: "\(originalFlag) "),
              wrapper.contains(modeFlag)
        else { return nil }
        // Only the payload token: a guarded wrapper carries more shell after
        // it, and decoding all of that as base64 would fail and leave the
        // wrapper looking like someone else's command.
        let encoded = wrapper[range.upperBound...]
            .prefix { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(encoded)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The command inside a `statusLine` value, in either the current object
    /// shape or the plain-string shape older files use.
    static func statusLineCommand(in value: Any?) -> String? {
        if let string = value as? String { return string }
        if let dictionary = value as? [String: Any] { return dictionary["command"] as? String }
        return nil
    }

    private func readRoot() -> [String: Any] {
        guard let data = try? Data(contentsOf: configURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return root
    }
}
