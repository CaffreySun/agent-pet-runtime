import Foundation
import Testing
@testable import AgentPetCore

/// Installing and removing the status-line tap.
///
/// This edits a key the user configured themselves and that shows up in every
/// one of their terminals, so the tests here are less about features than about
/// promises: their command keeps running, their other keys survive, and
/// removing the tap puts everything back.
@Suite("Status-line tap")
struct StatusLineTapTests {

    private struct Harness {
        let root: URL
        let settings: URL
        let store: IntegrationStore
        let tap: StatusLineTap

        init(settings existing: String) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("agentpet-tap-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            settings = root.appendingPathComponent("settings.json")
            try Data(existing.utf8).write(to: settings)
            store = IntegrationStore(directory: root.appendingPathComponent("integrations"))
            tap = StatusLineTap(
                configURL: settings,
                store: store,
                transaction: ConfigTransaction(backupDirectory: root.appendingPathComponent("backups"))
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func object() -> [String: Any] {
            (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any] ?? [:]
        }

        func statusLine() -> [String: Any]? { object()["statusLine"] as? [String: Any] }
        func command() -> String? { statusLine()?["command"] as? String }
    }

    private let theirSettings = """
    {
      "model": "sonnet",
      "statusLine": { "type": "command", "command": "bash -c 'claude-hud'", "padding": 0 }
    }
    """

    @Test("installing wraps the user's command instead of replacing it")
    func wrapsExistingCommand() throws {
        let harness = try Harness(settings: theirSettings)
        defer { harness.cleanup() }

        try harness.tap.configure(shimPath: "/Applications/AgentPet.app/agentpet-hook")

        let command = try #require(harness.command())
        #expect(command.contains("agentpet-hook"))
        #expect(command.contains(StatusLineTap.modeFlag))
        #expect(StatusLineTap.originalCommand(wrappedIn: command) == "bash -c 'claude-hud'")

        // Everything else about their status line survives.
        #expect(harness.statusLine()?["type"] as? String == "command")
        #expect(harness.statusLine()?["padding"] as? Int == 0)
        #expect(harness.object()["model"] as? String == "sonnet")

        #expect(harness.tap.state() == .installed(original: "bash -c 'claude-hud'"))
    }

    @Test("installing twice changes nothing the second time")
    func idempotent() throws {
        let harness = try Harness(settings: theirSettings)
        defer { harness.cleanup() }

        try harness.tap.configure(shimPath: "/Applications/AgentPet.app/agentpet-hook")
        let first = harness.command()
        let again = try harness.tap.configure(shimPath: "/Applications/AgentPet.app/agentpet-hook")

        #expect(harness.command() == first)
        #expect(!again.didChange, "a second install must be a no-op")
        #expect(harness.tap.state() == .installed(original: "bash -c 'claude-hud'"))
    }

    @Test("moving the app re-wraps the original command, not the wrapper")
    func reconfigureAfterMove() throws {
        let harness = try Harness(settings: theirSettings)
        defer { harness.cleanup() }

        try harness.tap.configure(shimPath: "/old/AgentPet.app/agentpet-hook")
        try harness.tap.configure(shimPath: "/Applications/AgentPet.app/agentpet-hook")

        let command = try #require(harness.command())
        #expect(command.contains("/Applications/"))
        #expect(!command.contains("/old/"))
        #expect(StatusLineTap.originalCommand(wrappedIn: command) == "bash -c 'claude-hud'",
                "re-installing must not nest a wrapper inside a wrapper")
    }

    @Test("removing the tap gives the user their status line back")
    func uninstallRestores() throws {
        let harness = try Harness(settings: theirSettings)
        defer { harness.cleanup() }

        try harness.tap.configure(shimPath: "/Applications/AgentPet.app/agentpet-hook")
        let outcome = try harness.tap.uninstall()

        #expect(outcome.didChange)
        #expect(harness.command() == "bash -c 'claude-hud'")
        #expect(harness.statusLine()?["padding"] as? Int == 0)
        #expect(harness.tap.state() == .notInstalled)
    }

    @Test("with no status line to begin with, removing the tap leaves none behind")
    func uninstallWithoutOriginal() throws {
        let harness = try Harness(settings: #"{ "model": "sonnet" }"#)
        defer { harness.cleanup() }

        try harness.tap.configure(shimPath: "/bin/agentpet-hook")
        #expect(harness.statusLine() != nil)

        try harness.tap.uninstall()
        #expect(harness.object()["statusLine"] == nil,
                "an empty status line we invented would be residue")
        #expect(harness.object()["model"] as? String == "sonnet")
    }

    @Test("a status line someone else wrote afterwards is left alone")
    func driftIsRespected() throws {
        let harness = try Harness(settings: theirSettings)
        defer { harness.cleanup() }

        try harness.tap.configure(shimPath: "/bin/agentpet-hook")
        // The user rewrites their status line by hand.
        var object = harness.object()
        object["statusLine"] = ["type": "command", "command": "echo hello"]
        try JSONSerialization.data(withJSONObject: object).write(to: harness.settings)

        #expect(harness.tap.state() == .drifted)

        let outcome = try harness.tap.uninstall()
        #expect(!outcome.didChange, "it is not ours to remove any more")
        #expect(harness.command() == "echo hello")
    }

    @Test("the wrapper round-trips, including an empty original")
    func commandRoundTrip() {
        let wrapped = StatusLineTap.wrapperCommand(shimPath: "/bin/shim", original: "bun hud.ts")
        #expect(wrapped.contains("--agent claude-code"))
        #expect(StatusLineTap.originalCommand(wrappedIn: wrapped) == "bun hud.ts")

        let bare = StatusLineTap.wrapperCommand(shimPath: "/bin/shim", original: nil)
        #expect(StatusLineTap.originalCommand(wrappedIn: bare) == "")

        // Not ours: an ordinary command is never mistaken for a wrapper.
        #expect(StatusLineTap.originalCommand(wrappedIn: "echo hi") == nil)
        #expect(StatusLineTap.originalCommand(wrappedIn: nil) == nil)
    }

    @Test("a status line stored as a plain string is still recognised")
    func plainStringStatusLine() throws {
        let harness = try Harness(settings: #"{ "statusLine": "my-hud" }"#)
        defer { harness.cleanup() }

        try harness.tap.configure(shimPath: "/bin/agentpet-hook")
        #expect(StatusLineTap.originalCommand(wrappedIn: harness.command()) == "my-hud")

        try harness.tap.uninstall()
        #expect(harness.command() == "my-hud")
    }
}

@Suite("Status-line normalization")
struct StatuslineNormalizationTests {

    private let normalizer = EventNormalizer(profiles: AgentProfiles.all)
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func envelope(_ event: String, payload: [String: Any]) -> BridgeEnvelope {
        BridgeEnvelope(
            agentID: "claude-code",
            eventName: event,
            receivedAt: origin,
            proc: BridgeProcessInfo(pid: 1, ppid: 2, tty: nil),
            rawPayload: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        )
    }

    @Test("a reduced status payload becomes a context update, not a state")
    func contextUpdate() throws {
        let events = normalizer.normalize(envelope("Statusline", payload: [
            "session_id": "abc-123",
            "session_name": "payment refactor",
            "used_percentage": 61.5,
            "window": 200_000,
            "tokens": 123_000,
            "project": "checkout",
        ]))

        let event = try #require(events.first)
        #expect(event.kind == .contextUpdate)
        #expect(event.sessionID == "abc-123")
        #expect(event.context?.usedPercent == 61.5)
        #expect(event.context?.sessionName == "payment refactor")
        #expect(event.kind.resultingState == nil, "a reading must not be usable as a state")
    }

    @Test("a status payload with nothing in it produces no event at all")
    func emptyStatus() {
        // Every session renders a status line from the moment it opens, and
        // before its first message there is nothing to say.
        #expect(normalizer.normalize(envelope("Statusline", payload: ["session_id": "abc"])).isEmpty)
    }

    @Test("a tool name is tracked separately from the summary")
    func toolNameIsItsOwnField() throws {
        // The prompt rule's summary is the user's prompt; it must never be
        // mistaken for a tool the panel can draw.
        let prompt = try #require(normalizer.normalize(envelope("UserPromptSubmit", payload: [
            "session_id": "a", "prompt": "refactor the payments module", "cwd": "/tmp/p",
        ])).first)
        #expect(prompt.toolName == nil)
        #expect(prompt.summary == "refactor the payments module")

        let tool = try #require(normalizer.normalize(envelope("PreToolUse", payload: [
            "session_id": "a", "tool_name": "Bash", "cwd": "/tmp/p",
        ])).first)
        #expect(tool.toolName == "Bash")
    }
}
