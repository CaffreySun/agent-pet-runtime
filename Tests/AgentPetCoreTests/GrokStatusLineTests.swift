import Foundation
import Testing
@testable import AgentPetCore

private final class GrokTapSandbox {
    let home: URL
    var configURL: URL { home.appendingPathComponent(".grok/config.toml") }

    init(configExisting: String? = nil) throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-groktap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".grok"), withIntermediateDirectories: true
        )
        if let configExisting { try Data(configExisting.utf8).write(to: configURL) }
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func tap() -> GrokStatusLine {
        GrokStatusLine(
            configURL: configURL,
            store: IntegrationStore(directory: home.appendingPathComponent("integrations")),
            transaction: ConfigTransaction(
                backupDirectory: home.appendingPathComponent("backups")
            )
        )
    }

    func configText() -> String {
        (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    }
}

private let grokTapNow = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("Grok status-line tap")
struct GrokStatusLineTests {

    @Test("enabling appends one section and leaves the rest of the file alone")
    func installs() throws {
        let sandbox = try GrokTapSandbox(configExisting: "model = \"grok-4.6\"\n[ui]\nfoo = 1\n")
        let outcome = try sandbox.tap().configure(shimPath: "/opt/agentpet/agentpet-hook", now: grokTapNow)

        #expect(outcome.didChange)
        let text = sandbox.configText()
        #expect(text.contains("model = \"grok-4.6\""))
        #expect(text.contains("[ui]\nfoo = 1"))
        #expect(text.contains("[ui.status_line]"))
        #expect(text.contains("type = \"command\""))
        #expect(text.contains("--agent grok --statusline"))
        #expect(sandbox.tap().state() == .installed)
    }

    @Test("the command never paints anything into the terminal")
    func commandPrintsNothing() {
        let command = GrokStatusLine.command(shimPath: "/opt/agentpet/agentpet-hook")
        // No printf, no echo: the row's absence is the contract, so the guard
        // is the whole command.
        #expect(command.hasPrefix("if [ -x "))
        #expect(command.hasSuffix("; fi"))
        #expect(!command.contains("echo"))
        #expect(!command.contains("printf"))
    }

    @Test("the block is exactly this text")
    func blockGolden() {
        // Pinned byte for byte: the machine-level acceptance run mirrors this
        // text into a real config.toml, and a format drift here would make
        // that proof worthless.
        let block = GrokStatusLine.block(shimPath: "/opt/agentpet/agentpet-hook")
        #expect(block.text == """
        # Written by Agent Pet Runtime: feeds session numbers to the pet.
        # The command prints nothing, so no status row appears.
        [ui.status_line]
        type = "command"
        command = "if [ -x /opt/agentpet/agentpet-hook ]; then /opt/agentpet/agentpet-hook --agent grok --statusline; fi"

        """)
    }

    @Test("a quote or backslash in the command value is escaped for TOML")
    func tomlEscaping() {
        #expect(GrokStatusLine.tomlString(#"a"b\c"#) == #""a\"b\\c""#)
    }

    @Test("enabling twice changes nothing")
    func idempotent() throws {
        let sandbox = try GrokTapSandbox(configExisting: "model = \"grok-4.6\"\n")
        let tap = sandbox.tap()
        _ = try tap.configure(shimPath: "/opt/agentpet/agentpet-hook", now: grokTapNow)
        let second = try tap.configure(shimPath: "/opt/agentpet/agentpet-hook", now: grokTapNow)

        #expect(!second.didChange)
        #expect(sandbox.configText().components(separatedBy: "[ui.status_line]").count == 2,
                "exactly one section")
    }

    @Test("a moved shim re-points the block instead of nesting a second one")
    func repointsAfterMove() throws {
        let sandbox = try GrokTapSandbox(configExisting: "model = \"grok-4.6\"\n")
        let tap = sandbox.tap()
        _ = try tap.configure(shimPath: "/old/AgentPet.app/Contents/MacOS/agentpet-hook", now: grokTapNow)
        let second = try tap.configure(shimPath: "/new/AgentPet.app/Contents/MacOS/agentpet-hook", now: grokTapNow)

        #expect(second.didChange)
        #expect(sandbox.configText().components(separatedBy: "[ui.status_line]").count == 2)
        #expect(sandbox.configText().contains("/new/AgentPet.app"))
        #expect(!sandbox.configText().contains("/old/AgentPet.app"))
        #expect(tap.state() == .installed)
    }

    @Test("a [ui.status_line] the user wrote is refused")
    func refusesForeignSection() throws {
        let sandbox = try GrokTapSandbox(configExisting: "[ui.status_line]\ntype = \"builtin\"\n")
        let before = sandbox.configText()

        #expect(throws: ConfigurationError.self) {
            _ = try sandbox.tap().configure(shimPath: "/opt/agentpet/agentpet-hook", now: grokTapNow)
        }
        #expect(sandbox.configText() == before)
    }

    @Test("disabling removes exactly what was added")
    func uninstallRestores() throws {
        let sandbox = try GrokTapSandbox(configExisting: "model = \"grok-4.6\"\n[ui]\nfoo = 1\n")
        let original = sandbox.configText()
        let tap = sandbox.tap()
        _ = try tap.configure(shimPath: "/opt/agentpet/agentpet-hook", now: grokTapNow)

        let removed = try tap.uninstall(now: grokTapNow)

        #expect(removed.didChange)
        #expect(sandbox.configText() == original, "the config must come back byte for byte")
        #expect(tap.state() == .notInstalled)
    }

    @Test("a user rewrite is drift, and removal leaves it alone")
    func driftLeavesUserContent() throws {
        let sandbox = try GrokTapSandbox(configExisting: "model = \"grok-4.6\"\n")
        let tap = sandbox.tap()
        _ = try tap.configure(shimPath: "/opt/agentpet/agentpet-hook", now: grokTapNow)

        let edited = sandbox.configText()
            .replacingOccurrences(of: "--agent grok --statusline",
                                  with: "--agent grok --statusline --mine")
        try Data(edited.utf8).write(to: sandbox.configURL)

        #expect(tap.state() == .drifted)
        _ = try tap.uninstall(now: grokTapNow)
        #expect(sandbox.configText().contains("--mine"), "their edit must survive removal")
    }
}
