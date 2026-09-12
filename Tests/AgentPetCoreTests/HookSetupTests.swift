import Foundation
import Testing
@testable import AgentPetCore

@Suite("Hook setup generation")
struct HookSetupTests {

    @Test("the generated configuration is valid JSON")
    func validJSON() throws {
        let json = HookSetup.claudeCodeJSON(shimPath: "/usr/local/bin/agentpet-hook")
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        #expect(object != nil)
        #expect(object?["hooks"] != nil)
    }

    @Test("every generated command names its agent and event explicitly")
    func commandsAreExplicit() throws {
        let json = HookSetup.claudeCodeJSON(shimPath: "/usr/local/bin/agentpet-hook")
        let hooks = try #require(
            (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["hooks"]
                as? [String: Any]
        )

        for (event, value) in hooks {
            let entries = try #require(value as? [[String: Any]])
            for entry in entries {
                let inner = try #require(entry["hooks"] as? [[String: Any]])
                let command = try #require(inner.first?["command"] as? String)
                // The shim must never have to guess what it is reporting.
                #expect(command.contains("--agent claude-code"), "\(event): \(command)")
                #expect(command.contains("--event \(event)"), "\(event): \(command)")
            }
        }
    }

    @Test("every command carries a timeout so a wedged shim cannot hold up the agent")
    func commandsHaveTimeout() throws {
        let json = HookSetup.claudeCodeJSON(shimPath: "/bin/agentpet-hook")
        let hooks = try #require(
            (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["hooks"]
                as? [String: Any]
        )
        for (_, value) in hooks {
            for entry in try #require(value as? [[String: Any]]) {
                for inner in try #require(entry["hooks"] as? [[String: Any]]) {
                    let timeout = try #require(inner["timeout"] as? Int)
                    #expect(timeout > 0 && timeout <= 10, "timeout \(timeout) is outside a sane range")
                }
            }
        }
    }

    @Test("the documented events are all present")
    func eventCoverage() throws {
        let json = HookSetup.claudeCodeJSON(shimPath: "/bin/agentpet-hook")
        let hooks = try #require(
            (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["hooks"]
                as? [String: Any]
        )
        for event in HookSetup.claudeCodeEvents {
            #expect(hooks[event] != nil, "\(event) missing from generated config")
        }
    }

    @Test("every generated event is one the normalizer understands")
    func eventsAreNormalizable() throws {
        // A hook that fires but maps to nothing would be a silent no-op.
        let normalizer = EventNormalizer(profiles: AgentProfiles.all)
        for event in HookSetup.claudeCodeEvents {
            let envelope = BridgeEnvelope(
                agentID: "claude-code",
                eventName: event,
                receivedAt: Date(),
                proc: BridgeProcessInfo(pid: 1, ppid: 2, tty: nil),
                rawPayload: Data()
            )
            #expect(!normalizer.normalize(envelope).isEmpty,
                    "\(event) generates a hook but normalizes to nothing")
        }
    }

    /// Pulls the command string out of the generated JSON, so assertions are
    /// about content rather than about escaping.
    private func commands(in json: String) throws -> [String] {
        let hooks = try #require(
            (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])?["hooks"]
                as? [String: Any]
        )
        return hooks.flatMap { _, value -> [String] in
            let entries = value as? [[String: Any]] ?? []
            return entries.flatMap { entry -> [String] in
                (entry["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
            }
        }
    }

    @Test("a path containing spaces is quoted so it stays one argument")
    func pathWithSpacesQuoted() throws {
        let json = HookSetup.claudeCodeJSON(shimPath: "/Applications/Agent Pet.app/agentpet-hook")
        for command in try commands(in: json) {
            #expect(command.hasPrefix("'/Applications/Agent Pet.app/agentpet-hook'"),
                    "unquoted path would split into separate arguments: \(command)")
        }
    }

    @Test("a path with spaces survives as exactly one argument when run through a shell")
    func quotedPathRunsAsOneArgument() throws {
        let shim = "/tmp/agent pet dir/hook"
        let command = "\(HookSetup.shellQuoted(shim)) --agent claude-code --event Stop"
        // Split the way a shell would, using the shell itself.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "set -- \(command); printf '%s\\n' \"$1\" \"$2\" \"$3\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first == shim, "the path was split: got \(lines)")
    }

    @Test("a plain path is left unquoted")
    func plainPathUnquoted() {
        #expect(HookSetup.shellQuoted("/usr/local/bin/agentpet-hook") == "/usr/local/bin/agentpet-hook")
    }

    @Test("an embedded single quote is escaped rather than breaking the command")
    func singleQuoteEscaped() {
        let quoted = HookSetup.shellQuoted("/tmp/it's here/hook")
        #expect(quoted.hasPrefix("'"))
        #expect(quoted.hasSuffix("'"))
        #expect(quoted.contains("'\\''"))
    }

    @Test("a path with an apostrophe still produces parseable JSON")
    func awkwardPathStillValidJSON() throws {
        let json = HookSetup.claudeCodeJSON(shimPath: "/tmp/o'brien/agentpet-hook")
        #expect((try? JSONSerialization.jsonObject(with: Data(json.utf8))) != nil)
    }
}
