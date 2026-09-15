import Foundation
import Testing
@testable import AgentPetCore

private final class PiSandbox {
    let home: URL
    var extensionURL: URL { home.appendingPathComponent(".pi/agent/extensions/agentpet.ts") }

    init() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func configurator() -> PiConfigurator {
        PiConfigurator(
            home: home,
            transaction: ConfigTransaction(
                backupDirectory: home.appendingPathComponent("backups")
            )
        )
    }

    func fileText() -> String? {
        (try? Data(contentsOf: extensionURL)).flatMap { String(data: $0, encoding: .utf8) }
    }

    func writeForeignFile() throws {
        try FileManager.default.createDirectory(
            at: extensionURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("// my own extension\nexport default function (pi) {}\n".utf8)
            .write(to: extensionURL)
    }
}

private let piShim = "/opt/agentpet/agentpet-hook"
private let piNow = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("Pi configuration")
struct PiConfigurationTests {

    @Test("every event the extension sends is one the normalizer knows about")
    func emittedEventsAreKnown() throws {
        let rules = try #require(AgentProfiles.profile(for: "pi"))
        let known = Set(rules.rules.flatMap(\.matches))
        let emitted = [
            "session_start", "agent_start", "tool_execution_start",
            "ui_prompt_start", "agent_settled", "session_shutdown", "context_update",
        ]
        for event in emitted {
            #expect(known.contains(event), "\(event) is sent but unknown to the normalizer")
        }
    }

    @Test("configuring writes one marked file and nothing else")
    func installs() throws {
        let sandbox = try PiSandbox()
        let outcome = try sandbox.configurator().configure(shimPath: piShim, replacing: nil, now: piNow)

        #expect(outcome.didChange)
        #expect(outcome.record.isConfigured)
        let text = try #require(sandbox.fileText())
        #expect(text.contains(PiConfigurator.marker))
        #expect(text.contains(piShim))
        #expect(text.contains("--agent") && text.contains("pi"))
        #expect(sandbox.configurator().entriesPresent(in: outcome.record))

        // The only thing under home is Pi's own directory: no settings edit,
        // no backup (nothing existed to back up), no package.
        let top = try FileManager.default.contentsOfDirectory(atPath: sandbox.home.path)
        #expect(top == [".pi"])
    }

    @Test("configuring twice changes nothing")
    func idempotent() throws {
        let sandbox = try PiSandbox()
        let configurator = sandbox.configurator()
        _ = try configurator.configure(shimPath: piShim, replacing: nil, now: piNow)
        let second = try configurator.configure(shimPath: piShim, replacing: nil, now: piNow)
        #expect(!second.didChange)
    }

    @Test("a moved shim shows up as drift")
    func movedShimIsDrift() throws {
        let sandbox = try PiSandbox()
        let outcome = try sandbox.configurator().configure(shimPath: piShim, replacing: nil, now: piNow)

        var moved = outcome.record
        moved.shimPath = "/somewhere/else/agentpet-hook"
        #expect(!sandbox.configurator().entriesPresent(in: moved))
    }

    @Test("a file the user wrote is refused, never overwritten")
    func refusesForeignFile() throws {
        let sandbox = try PiSandbox()
        try sandbox.writeForeignFile()
        let before = sandbox.fileText()

        #expect(throws: ConfigurationError.self) {
            _ = try sandbox.configurator().configure(shimPath: piShim, replacing: nil, now: piNow)
        }
        #expect(sandbox.fileText() == before)
    }

    @Test("uninstalling deletes the runtime's file, with a backup")
    func uninstallDeletes() throws {
        let sandbox = try PiSandbox()
        let configurator = sandbox.configurator()
        let installed = try configurator.configure(shimPath: piShim, replacing: nil, now: piNow)

        let removed = try configurator.uninstall(installed.record, now: piNow)

        #expect(removed.didChange)
        #expect(removed.record.status == .notConfigured)
        #expect(!FileManager.default.fileExists(atPath: sandbox.extensionURL.path))
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: sandbox.home.appendingPathComponent("backups").path
        )
        #expect(backups.count == 1, "the deleted file must exist in the backup directory")
    }

    @Test("uninstall leaves a file the runtime did not write alone")
    func uninstallLeavesForeignFile() throws {
        let sandbox = try PiSandbox()
        try sandbox.writeForeignFile()
        let before = sandbox.fileText()
        let record = IntegrationRecord(
            agentID: "pi", status: .configured,
            shimPath: piShim,
            entries: [WrittenEntry(file: sandbox.extensionURL.path, event: "extension", command: PiConfigurator.marker)]
        )

        let outcome = try sandbox.configurator().uninstall(record, now: piNow)

        #expect(!outcome.didChange)
        #expect(sandbox.fileText() == before)
    }
}
