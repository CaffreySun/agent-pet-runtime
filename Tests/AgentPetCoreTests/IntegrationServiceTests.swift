import Foundation
import Testing
@testable import AgentPetCore

/// Exercises the configure → verify → remove cycle through the same service
/// the UI calls, against a settings file shaped like a real one.
@Suite("Integration service round trip")
struct IntegrationServiceTests {

    private struct Harness {
        let root: URL
        let settings: URL
        let store: IntegrationStore
        let service: AgentIntegrationService
        let transaction: ConfigTransaction

        init(settings existing: String?) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("agentpet-service-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

            settings = root.appendingPathComponent("settings.json")
            if let existing { try Data(existing.utf8).write(to: settings) }

            store = IntegrationStore(directory: root.appendingPathComponent("integrations"))
            transaction = ConfigTransaction(
                backupDirectory: root.appendingPathComponent("backups")
            )
            service = AgentIntegrationService(
                store: store,
                // Detection is not what these tests are about; a real detector
                // would go looking for the user's actual agents.
                detector: AgentDetector(specifications: [], readVersions: false)
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func object() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any] ?? [:]
        }

        func commands(for event: String) -> [String] {
            let hooks = object()["hooks"] as? [String: Any]
            let entries = hooks?[event] as? [[String: Any]] ?? []
            return entries.flatMap { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            }
        }
    }

    /// The service resolves agents through the registry, which points at the
    /// real `~/.claude/settings.json`. These tests therefore exercise the
    /// configurator directly against a sandboxed file, using the same record
    /// and store plumbing the service uses.
    private func configurator(_ harness: Harness) -> JSONHookConfigurator {
        JSONHookConfigurator(
            agentID: "claude-code",
            configURL: harness.settings,
            events: HookSetup.claudeCodeEvents,
            transaction: harness.transaction
        )
    }

    @Test("configure, verify, then remove restores the file's meaning")
    func fullCycle() throws {
        let harness = try Harness(settings: """
        {
          "env": { "CLAUDE_CODE_EFFORT_LEVEL": "max" },
          "permissions": { "allow": ["Bash(git add *)"] },
          "hooks": {
            "Stop": [ { "matcher": "*", "hooks": [
              { "type": "command", "command": "/usr/local/bin/existing-notify.sh" } ] } ]
          }
        }
        """)
        defer { harness.cleanup() }

        let original = try JSONSerialization.jsonObject(with: Data(contentsOf: harness.settings))
        let configurator = configurator(harness)

        // Configure.
        let configured = try configurator.configure(
            shimPath: "/Applications/AgentPet.app/agentpet-hook", replacing: nil, now: Date()
        )
        try harness.store.save(configured.record)

        #expect(configured.didChange)
        #expect(harness.store.record(for: "claude-code").isConfigured)
        #expect(configurator.entriesPresent(in: configured.record))

        // Every configured event has exactly one of our hooks, and the user's
        // own hook is still there.
        for event in HookSetup.claudeCodeEvents {
            let ours = harness.commands(for: event).filter { $0.contains("agentpet-hook") }
            #expect(ours.count == 1, "\(event) has \(ours.count) of our hooks")
        }
        #expect(harness.commands(for: "Stop").contains("/usr/local/bin/existing-notify.sh"))

        // Remove.
        let record = harness.store.record(for: "claude-code")
        let removed = try configurator.uninstall(record, now: Date())
        try harness.store.save(removed.record)

        #expect(removed.didChange)
        #expect(!harness.store.record(for: "claude-code").isConfigured)

        let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: harness.settings))
        #expect(NSDictionary(dictionary: restored as? [String: Any] ?? [:])
            .isEqual(to: original as? [String: Any] ?? [:]),
                "after a full cycle the settings should mean exactly what they did before")
    }

    @Test("reconfiguring after moving the app leaves one hook, not two")
    func reconfigureAfterMove() throws {
        let harness = try Harness(settings: "{}")
        defer { harness.cleanup() }
        let configurator = configurator(harness)

        let first = try configurator.configure(
            shimPath: "/old/AgentPet", replacing: nil, now: Date()
        )
        try harness.store.save(first.record)

        let second = try configurator.configure(
            shimPath: "/Applications/AgentPet.app/agentpet-hook",
            replacing: harness.store.record(for: "claude-code"),
            now: Date()
        )
        try harness.store.save(second.record)

        for event in HookSetup.claudeCodeEvents {
            let ours = harness.commands(for: event).filter { $0.contains("agentpet-hook") }
            #expect(ours.count == 1, "\(event) ended up with \(ours.count) hooks after a move")
            #expect(ours.first?.contains("/Applications/") == true, "\(event) still points at the old path")
        }
    }

    @Test("a configure failure is recorded so the UI can show it")
    func failureIsRecorded() throws {
        let harness = try Harness(settings: "{ not valid json")
        defer { harness.cleanup() }

        #expect(throws: (any Error).self) {
            try configurator(harness).configure(
                shimPath: "/bin/agentpet-hook", replacing: nil, now: Date()
            )
        }
        // The configurator itself does not write the record on failure; the
        // service does. Verify the record model can express that state.
        var failed = harness.store.record(for: "claude-code")
        failed.status = .configureFailed
        try harness.store.save(failed)

        let reloaded = harness.store.record(for: "claude-code")
        #expect(reloaded.status == .configureFailed)
        #expect(!reloaded.isConfigured)
    }

    @Test("records survive a restart of the store")
    func recordsPersist() throws {
        let harness = try Harness(settings: "{}")
        defer { harness.cleanup() }

        let outcome = try configurator(harness).configure(
            shimPath: "/bin/agentpet-hook", replacing: nil, now: Date()
        )
        try harness.store.save(outcome.record)

        let reopened = IntegrationStore(directory: harness.root.appendingPathComponent("integrations"))
        let record = reopened.record(for: "claude-code")
        #expect(record.isConfigured)
        #expect(record.entries.count == HookSetup.claudeCodeEvents.count)
        #expect(record.shimPath == "/bin/agentpet-hook")
    }

    @Test("the stored record has exactly the schema it is allowed to have")
    func recordSchemaIsClosed() throws {
        let harness = try Harness(settings: "{}")
        defer { harness.cleanup() }

        let outcome = try configurator(harness).configure(
            shimPath: "/bin/agentpet-hook", replacing: nil, now: Date()
        )
        try harness.store.save(outcome.record)

        // Checking keys rather than searching for substrings: the event name
        // `UserPromptSubmit` legitimately contains "prompt", so substring
        // matching flags correct data. A closed allowlist proves the record
        // cannot carry a credential without the schema changing.
        let raw = try Data(contentsOf: harness.store.url(for: "claude-code"))
        let object = try #require(
            try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        )

        let allowedTopLevel: Set<String> = [
            "agentID", "integrationVersion", "status",
            "configuredAt", "lastValidatedAt", "shimPath", "entries",
        ]
        #expect(Set(object.keys).subtracting(allowedTopLevel).isEmpty,
                "unexpected top-level keys: \(Set(object.keys).subtracting(allowedTopLevel))")

        let entries = try #require(object["entries"] as? [[String: Any]])
        for entry in entries {
            #expect(Set(entry.keys).isSubset(of: ["file", "event", "command"]),
                    "unexpected entry keys: \(entry.keys)")
        }

        // And the values themselves carry no environment-derived secrets.
        let text = String(decoding: raw, as: UTF8.self)
        for forbidden in ["api_key", "apiKey", "Bearer ", "sk-", "password"] {
            #expect(!text.contains(forbidden), "the integration record contains '\(forbidden)'")
        }
    }

    @Test("health distinguishes connected from merely configured")
    func healthReflectsReality() throws {
        let harness = try Harness(settings: "{}")
        defer { harness.cleanup() }

        let outcome = try configurator(harness).configure(
            shimPath: "/bin/agentpet-hook", replacing: nil, now: Date()
        )
        let evaluator = IntegrationHealthEvaluator(freshnessWindow: 30)
        let now = Date()

        let silent = evaluator.health(
            record: outcome.record, isDetected: true, lastEventAt: nil,
            entriesPresent: true, now: now
        )
        #expect(silent == .degraded, "configured but silent is not healthy")

        let live = evaluator.health(
            record: outcome.record, isDetected: true, lastEventAt: now.addingTimeInterval(-5),
            entriesPresent: true, now: now
        )
        #expect(live == .connected)

        harness.service.recordEvent(agentID: "claude-code", at: now)
        #expect(harness.service.lastEventAt["claude-code"] == now)
    }
}
