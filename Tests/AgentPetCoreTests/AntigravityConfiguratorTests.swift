import Foundation
import Testing
@testable import AgentPetCore

private final class AntigravitySandbox {
    let home: URL
    var hooksURL: URL { home.appendingPathComponent(".gemini/config/hooks.json") }

    init(hooksExisting: String? = nil) throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-ag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".gemini/config"), withIntermediateDirectories: true
        )
        if let hooksExisting { try Data(hooksExisting.utf8).write(to: hooksURL) }
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func configurator() -> AntigravityConfigurator {
        AntigravityConfigurator(
            home: home,
            transaction: ConfigTransaction(
                backupDirectory: home.appendingPathComponent("backups")
            )
        )
    }

    func root() -> [String: Any] {
        guard let data = try? Data(contentsOf: hooksURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return object
    }

    func named() -> [String: Any] {
        root()[AntigravityConfigurator.hookName] as? [String: Any] ?? [:]
    }
}

private let agShim = "/opt/agentpet/agentpet-hook"
private let agNow = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("Antigravity configuration")
struct AntigravityConfigurationTests {

    @Test("installing writes the one named hook, in the shape each event takes")
    func installs() throws {
        let sandbox = try AntigravitySandbox()
        let outcome = try sandbox.configurator().configure(shimPath: agShim, replacing: nil, now: agNow)

        #expect(outcome.record.isConfigured)
        #expect(outcome.record.entries.count == AntigravityConfigurator.events.count)

        let named = sandbox.named()
        // Flat events are bare handler lists.
        let stop = named["Stop"] as? [[String: Any]]
        #expect(stop?.first?["command"] as? String == "\(agShim) --agent antigravity --event Stop")
        #expect(stop?.first?["hooks"] == nil, "Stop is flat — no matcher wrapper")
        // Tool events are matcher groups.
        let tool = named["PostToolUse"] as? [[String: Any]]
        #expect(tool?.first?["matcher"] as? String == "*")
        #expect((tool?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
                == "\(agShim) --agent antigravity --event PostToolUse")
        // And the gating event is never installed: its result must carry a
        // `decision`, the shim answers `{}`, and a decision-less result denies
        // the tool call (empty reason included). See the type's doc comment.
        #expect(named["PreToolUse"] == nil, "a decision-less PreToolUse result denies every tool call")
        // The undocumented-but-real event is installed too.
        #expect(named["SessionStart"] != nil)
        #expect(sandbox.configurator().entriesPresent(in: outcome.record))
    }

    @Test("installing around another named hook leaves it untouched")
    func preservesForeignHooks() throws {
        let foreign = #"{"lint-checker": {"PostToolUse": [{"matcher": "run_command", "hooks": [{"type": "command", "command": "./lint.sh"}]}]}}"#
        let sandbox = try AntigravitySandbox(hooksExisting: foreign)
        let outcome = try sandbox.configurator().configure(shimPath: agShim, replacing: nil, now: agNow)

        #expect(sandbox.root()["lint-checker"] != nil, "the user's hook must survive install")
        _ = try sandbox.configurator().uninstall(outcome.record, now: agNow)
        #expect(sandbox.root()["lint-checker"] != nil, "and survive removal")
        #expect(sandbox.root()["agentpet"] == nil)
    }

    @Test("configuring twice changes nothing")
    func idempotent() throws {
        let sandbox = try AntigravitySandbox()
        let configurator = sandbox.configurator()
        _ = try configurator.configure(shimPath: agShim, replacing: nil, now: agNow)
        let second = try configurator.configure(shimPath: agShim, replacing: nil, now: agNow)
        #expect(!second.didChange)
    }

    @Test("a moved shim re-points the named hook instead of nesting")
    func repointsAfterMove() throws {
        let sandbox = try AntigravitySandbox()
        let configurator = sandbox.configurator()
        _ = try configurator.configure(shimPath: "/old/agentpet-hook", replacing: nil, now: agNow)
        let second = try configurator.configure(shimPath: "/new/agentpet-hook", replacing: nil, now: agNow)

        #expect(second.didChange)
        #expect(sandbox.configurator().entriesPresent(in: second.record))
        let stop = sandbox.named()["Stop"] as? [[String: Any]]
        #expect(stop?.first?["command"] as? String == "/new/agentpet-hook --agent antigravity --event Stop")
        #expect(!((sandbox.named()["Stop"] as? [[String: Any]])?.isEmpty ?? true))
    }

    @Test("a user edit inside the named hook means drift, and removal leaves it alone")
    func driftLeavesUserEdit() throws {
        let sandbox = try AntigravitySandbox()
        let configurator = sandbox.configurator()
        let installed = try configurator.configure(shimPath: agShim, replacing: nil, now: agNow)

        var named = sandbox.named()
        var stop = named["Stop"] as? [[String: Any]] ?? []
        stop[0]["command"] = "\(agShim) --agent antigravity --event Stop --mine"
        named["Stop"] = stop
        var root = sandbox.root()
        root["agentpet"] = named
        try JSONSerialization.data(withJSONObject: root).write(to: sandbox.hooksURL)

        #expect(!configurator.entriesPresent(in: installed.record))
        _ = try configurator.uninstall(installed.record, now: agNow)
        #expect(sandbox.root()["agentpet"] != nil, "their edit must survive removal")
    }

    /// The config 0.10.x wrote, PreToolUse and all: the first two entries are
    /// what its record listed.
    private func legacySandbox() throws -> (AntigravitySandbox, IntegrationRecord) {
        let sandbox = try AntigravitySandbox(hooksExisting: """
        {
          "lint-checker": { "PostToolUse": [ { "matcher": "run_command", "hooks": [
            { "type": "command", "command": "./lint.sh" } ] } ] },
          "agentpet": {
            "PreToolUse": [ { "matcher": "*", "hooks": [
              { "type": "command", "command": "\(agShim) --agent antigravity --event PreToolUse",
                "timeout": 5 } ] } ],
            "Stop": [ { "type": "command",
              "command": "\(agShim) --agent antigravity --event Stop", "timeout": 5 } ]
          }
        }
        """)
        let record = IntegrationRecord(
            agentID: "antigravity",
            status: .configured,
            configuredAt: agNow,
            shimPath: agShim,
            entries: [
                WrittenEntry(
                    file: sandbox.hooksURL.path,
                    event: "PreToolUse",
                    command: "\(agShim) --agent antigravity --event PreToolUse"
                ),
                WrittenEntry(
                    file: sandbox.hooksURL.path,
                    event: "Stop",
                    command: "\(agShim) --agent antigravity --event Stop"
                ),
            ]
        )
        return (sandbox, record)
    }

    @Test("an older config loses the line that gated every tool call, and only that")
    func migratesObsoleteEntry() throws {
        let (sandbox, record) = try legacySandbox()
        let configurator = sandbox.configurator()

        // The obsolete event reads as drift while it is there.
        #expect(!configurator.entriesPresent(in: record))

        let outcome = try #require(try configurator.removeObsoleteEntries(record, now: agNow))
        #expect(outcome.didChange)
        #expect(sandbox.named()["PreToolUse"] == nil)
        let stop = sandbox.named()["Stop"] as? [[String: Any]]
        #expect(stop?.first?["command"] as? String == "\(agShim) --agent antigravity --event Stop")
        #expect(sandbox.root()["lint-checker"] != nil, "another tool's named hook is untouched")

        #expect(configurator.entriesPresent(in: outcome.record))
        #expect(outcome.record.entries.map(\.event) == ["Stop"])
        #expect(outcome.record.shimPath == agShim, "a migration does not re-point the shim")
        #expect(outcome.record.configuredAt == agNow)
    }

    @Test("a migration refuses while a human has edited inside the named hook")
    func migrationLeavesEditedHookAlone() throws {
        let (sandbox, record) = try legacySandbox()
        var named = sandbox.named()
        named["Stop"] = [[
            "type": "command",
            "command": "\(agShim) --agent antigravity --event Stop --mine",
            "timeout": 5,
        ]]
        var root = sandbox.root()
        root[AntigravityConfigurator.hookName] = named
        try JSONSerialization.data(withJSONObject: root).write(to: sandbox.hooksURL)

        let configurator = sandbox.configurator()
        #expect(try configurator.removeObsoleteEntries(record, now: agNow) == nil)
        #expect(sandbox.named()["PreToolUse"] != nil, "nothing happens behind the user's edit")
    }

    @Test("nothing to migrate on a config this version wrote")
    func migrationIsNoOpWhenCurrent() throws {
        let sandbox = try AntigravitySandbox()
        let configurator = sandbox.configurator()
        let installed = try configurator.configure(shimPath: agShim, replacing: nil, now: agNow)
        #expect(try configurator.removeObsoleteEntries(installed.record, now: agNow) == nil)
    }
}
