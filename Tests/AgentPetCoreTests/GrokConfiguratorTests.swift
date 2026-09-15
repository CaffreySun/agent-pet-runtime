import Foundation
import Testing
@testable import AgentPetCore

private final class GrokSandbox {
    let home: URL
    var configURL: URL { home.appendingPathComponent(".grok/config.toml") }
    var hooksURL: URL { home.appendingPathComponent(".grok/hooks/agentpet.json") }

    init(configExisting: String? = nil) throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-grok-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".grok"), withIntermediateDirectories: true
        )
        if let configExisting { try Data(configExisting.utf8).write(to: configURL) }
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func configurator() -> GrokConfigurator {
        GrokConfigurator(
            home: home,
            transaction: ConfigTransaction(
                backupDirectory: home.appendingPathComponent("backups")
            )
        )
    }

    func configText() -> String {
        (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    }

    func hookCommands(for event: String) -> [String] {
        guard let data = try? Data(contentsOf: hooksURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let hooks = object["hooks"] as? [String: Any],
              let entries = hooks[event] as? [[String: Any]]
        else { return [] }
        return entries.flatMap { entry in
            (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }
}

private let grokShim = "/opt/agentpet/agentpet-hook"
private let grokNow = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("Grok configuration")
struct GrokConfigurationTests {

    @Test("configuring writes the hooks file and the compat switch")
    func installs() throws {
        let sandbox = try GrokSandbox(configExisting: "model = \"grok-4.6\"\n")
        let outcome = try sandbox.configurator().configure(shimPath: grokShim, replacing: nil, now: grokNow)

        #expect(outcome.record.isConfigured)
        #expect(outcome.changedFiles.count == 2)
        #expect(sandbox.hookCommands(for: "SessionStart").count == 1)
        #expect(sandbox.hookCommands(for: "StopCancelled").count == 1)
        #expect(outcome.record.entries.count == GrokConfigurator.events.count + 1)
        #expect(sandbox.configText().contains("[compat.claude]"))
        #expect(sandbox.configText().contains("hooks = false"))
        #expect(sandbox.configText().contains("model = \"grok-4.6\""), "the user's own lines stay")
        #expect(outcome.record.entries.contains { $0.event == GrokConfigurator.compatEntryEvent })
    }

    @Test("configuring twice changes nothing")
    func idempotent() throws {
        let sandbox = try GrokSandbox(configExisting: "model = \"grok-4.6\"\n")
        let configurator = sandbox.configurator()
        let first = try configurator.configure(shimPath: grokShim, replacing: nil, now: grokNow)
        let second = try configurator.configure(shimPath: grokShim, replacing: first.record, now: grokNow)

        #expect(!second.didChange, "the second configure must be a no-op")
        #expect(sandbox.hookCommands(for: "Stop").count == 1)
        #expect(sandbox.configText().components(separatedBy: "[compat.claude]").count == 2,
                "exactly one table")
    }

    @Test("a config file that does not end in a newline is not mangled")
    func missingTrailingNewline() throws {
        let sandbox = try GrokSandbox(configExisting: "model = \"grok-4.6\"")
        _ = try sandbox.configurator().configure(shimPath: grokShim, replacing: nil, now: grokNow)

        let text = sandbox.configText()
        #expect(text.hasPrefix("model = \"grok-4.6\"\n"), "the last line is terminated, not merged")
        #expect(text.contains("\n[compat.claude]\n"))
    }

    @Test("a [compat.claude] table the user wrote is refused, and this call's writes are undone")
    func refusesForeignTable() throws {
        let sandbox = try GrokSandbox(configExisting: "[compat.claude]\nagents = false\n")
        let before = sandbox.configText()

        #expect(throws: ConfigurationError.self) {
            _ = try sandbox.configurator().configure(shimPath: grokShim, replacing: nil, now: grokNow)
        }
        #expect(sandbox.configText() == before, "the user's config must be untouched")
        #expect(sandbox.hookCommands(for: "Stop").isEmpty,
                "no hooks may be left installed without the switch")
    }

    @Test("a refused reconfigure does not take away a working hooks file")
    func refusedReconfigureKeepsHooks() throws {
        let sandbox = try GrokSandbox(configExisting: "model = \"x\"\n")
        let configurator = sandbox.configurator()
        let first = try configurator.configure(shimPath: grokShim, replacing: nil, now: grokNow)

        // The user edits our block afterwards, turning the scan back on.
        let edited = sandbox.configText()
            .replacingOccurrences(of: "hooks = false", with: "hooks = true")
        try Data(edited.utf8).write(to: sandbox.configURL)

        #expect(throws: ConfigurationError.self) {
            _ = try configurator.configure(shimPath: grokShim, replacing: first.record, now: grokNow)
        }
        #expect(sandbox.hookCommands(for: "Stop").count == 1,
                "the hooks file that was working must survive a refused reconfigure")
    }

    @Test("uninstalling removes exactly what was written")
    func uninstallRestores() throws {
        let sandbox = try GrokSandbox(
            configExisting: "model = \"grok-4.6\"\n[mcp_servers.fff]\ncommand = \"fff\"\n"
        )
        let original = sandbox.configText()
        let configurator = sandbox.configurator()
        let installed = try configurator.configure(shimPath: grokShim, replacing: nil, now: grokNow)

        let removed = try configurator.uninstall(installed.record, now: grokNow)

        #expect(removed.record.status == .notConfigured)
        #expect(sandbox.configText() == original, "the config must come back byte for byte")
        #expect(sandbox.hookCommands(for: "Stop").isEmpty)
    }

    @Test("a user rewrite of the switch means drift, and removal leaves their edit alone")
    func driftLeavesUserContent() throws {
        let sandbox = try GrokSandbox(configExisting: "model = \"grok-4.6\"\n")
        let configurator = sandbox.configurator()
        let installed = try configurator.configure(shimPath: grokShim, replacing: nil, now: grokNow)

        let edited = sandbox.configText()
            .replacingOccurrences(of: "hooks = false", with: "hooks = true")
        try Data(edited.utf8).write(to: sandbox.configURL)

        #expect(!configurator.entriesPresent(in: installed.record), "health must notice the drift")
        _ = try configurator.uninstall(installed.record, now: grokNow)
        #expect(sandbox.configText().contains("hooks = true"), "their edit must survive removal")
    }

    @Test("a first run that finds the canonical switch already present records it")
    func canonicalSwitchAlreadyPresent() throws {
        let sandbox = try GrokSandbox(
            configExisting: "model = \"grok-4.6\"\n\n" + GrokConfigurator.compatSwitch.text
        )
        let outcome = try sandbox.configurator().configure(shimPath: grokShim, replacing: nil, now: grokNow)

        #expect(outcome.record.isConfigured)
        #expect(outcome.record.entries.contains { $0.event == GrokConfigurator.compatEntryEvent })
        #expect(sandbox.configText().components(separatedBy: "[compat.claude]").count == 2)
    }
}
