import Foundation
import Testing
@testable import AgentPetCore

private final class AntigravitySettingsSandbox {
    let home: URL
    var settingsURL: URL { home.appendingPathComponent(".gemini/antigravity-cli/settings.json") }

    init(settingsExisting: String? = nil) throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-agsettings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".gemini/antigravity-cli"),
            withIntermediateDirectories: true
        )
        if let settingsExisting { try Data(settingsExisting.utf8).write(to: settingsURL) }
    }

    deinit { try? FileManager.default.removeItem(at: home) }

    func tap() -> AntigravityStatusLine {
        AntigravityStatusLine(
            configURL: settingsURL,
            store: IntegrationStore(directory: home.appendingPathComponent("integrations")),
            transaction: ConfigTransaction(
                backupDirectory: home.appendingPathComponent("backups")
            )
        )
    }

    func root() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [:] }
        return object
    }

    func statusLine() -> [String: Any]? {
        root()["statusLine"] as? [String: Any]
    }
}

private let agTapShim = "/opt/agentpet/agentpet-hook"
private let agTapNow = Date(timeIntervalSince1970: 1_700_000_000)

@Suite("Antigravity status-line tap")
struct AntigravityStatusLineTests {

    @Test("installing writes the row-rendering command and leaves settings alone")
    func installs() throws {
        let sandbox = try AntigravitySettingsSandbox(
            settingsExisting: #"{"trustedWorkspaces": ["/Users/x/Documents"]}"#
        )
        let outcome = try sandbox.tap().configure(shimPath: agTapShim, now: agTapNow)

        #expect(outcome.didChange)
        #expect(sandbox.statusLine()?["type"] as? String == "command")
        let command = sandbox.statusLine()?["command"] as? String
        #expect(command?.contains("--agent antigravity --statusline --render-row") == true)
        #expect(command?.hasPrefix("if [ -x ") == true)
        #expect(sandbox.root()["trustedWorkspaces"] != nil, "the rest of the settings stay")
        #expect(sandbox.tap().state() == .installed)
    }

    @Test("a status-line command the user wrote is refused")
    func refusesForeignCommand() throws {
        let sandbox = try AntigravitySettingsSandbox(
            settingsExisting: #"{"statusLine": {"type": "command", "command": "/usr/local/bin/mystatus"}}"#
        )
        let before = sandbox.root()

        #expect(throws: ConfigurationError.self) {
            _ = try sandbox.tap().configure(shimPath: agTapShim, now: agTapNow)
        }
        #expect(NSDictionary(dictionary: sandbox.root()).isEqual(NSDictionary(dictionary: before)))
    }

    @Test("the builtin default is replaceable, and restored on removal")
    func builtinDefaultRoundTrip() throws {
        let sandbox = try AntigravitySettingsSandbox(
            settingsExisting: #"{"statusLine": {"type": "builtin"}, "trustedWorkspaces": []}"#
        )
        let tap = sandbox.tap()
        _ = try tap.configure(shimPath: agTapShim, now: agTapNow)
        #expect(sandbox.statusLine()?["type"] as? String == "command")

        _ = try tap.uninstall(now: agTapNow)
        #expect(sandbox.statusLine()?["type"] as? String == "builtin",
                "the exact previous value must come back")
        #expect(tap.state() == .notInstalled)
    }

    @Test("removing with nothing before us leaves no empty section behind")
    func removalWithoutOriginal() throws {
        let sandbox = try AntigravitySettingsSandbox(settingsExisting: #"{"trustedWorkspaces": []}"#)
        let tap = sandbox.tap()
        _ = try tap.configure(shimPath: agTapShim, now: agTapNow)
        _ = try tap.uninstall(now: agTapNow)
        #expect(sandbox.root()["statusLine"] == nil)
        #expect(sandbox.root()["trustedWorkspaces"] != nil)
    }

    @Test("configuring twice changes nothing, and a user edit is drift")
    func idempotentAndDrift() throws {
        let sandbox = try AntigravitySettingsSandbox(settingsExisting: "{}")
        let tap = sandbox.tap()
        _ = try tap.configure(shimPath: agTapShim, now: agTapNow)
        #expect(!(try tap.configure(shimPath: agTapShim, now: agTapNow)).didChange)

        var root = sandbox.root()
        root["statusLine"] = ["type": "command", "command": "/somewhere/else"]
        try JSONSerialization.data(withJSONObject: root).write(to: sandbox.settingsURL)
        #expect(tap.state() == .drifted)

        _ = try tap.uninstall(now: agTapNow)
        #expect((sandbox.statusLine()?["command"] as? String) == "/somewhere/else",
                "their edit must survive removal")
    }
}
