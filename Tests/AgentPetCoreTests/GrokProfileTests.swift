import Foundation
import Testing
@testable import AgentPetCore

/// Payloads captured from a real Grok 1.0.24 session on 2026-09-15 and then
/// reduced to synthetic values: the wire shape is the point, and the repository
/// carries no machine-specific content. See docs/ARCHITECTURE.md §6.7b.
private func grokFixture(_ name: String) throws -> String {
    let stem = name.hasSuffix(".json") ? String(name.dropLast(".json".count)) : name
    let url = Bundle.module.url(
        forResource: "Fixtures/grok/\(stem)",
        withExtension: "json"
    )
    guard let url else {
        Issue.record("missing fixture \(name).json")
        throw NormalizationError.notJSON
    }
    return try String(contentsOf: url, encoding: .utf8)
}

private func grokEnvelope(_ event: String, payload: String) -> BridgeEnvelope {
    BridgeEnvelope(
        agentID: "grok",
        eventName: event,
        receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
        proc: BridgeProcessInfo(pid: 100, ppid: 50, tty: "/dev/ttys001"),
        rawPayload: Data(payload.utf8)
    )
}

@Suite("Grok normalization (captured payloads)")
struct GrokNormalizationTests {

    private let normalizer = EventNormalizer(profiles: AgentProfiles.all)
    private let session = "55555555-5555-4555-8555-555555555555"

    @Test("captured wire payloads map to the right kinds", arguments: [
        ("session-start.json", "SessionStart", AgentEventKind.sessionStarted),
        ("user-prompt-submit.json", "UserPromptSubmit", .working),
        ("pre-tool-use.json", "PreToolUse", .working),
        ("post-tool-use.json", "PostToolUse", .working),
        ("stop-end-turn.json", "Stop", .completed),
        ("session-end.json", "SessionEnd", .sessionClosed),
    ])
    func capturedPayloads(file: String, event: String, kind: AgentEventKind) throws {
        let events = normalizer.normalize(grokEnvelope(event, payload: try grokFixture(file)))
        #expect(events.count == 1)
        #expect(events.first?.kind == kind)
        #expect(events.first?.sessionID == session, "the session_id alias must be read")
    }

    @Test("the shutdown Stop is not a turn ending")
    func shutdownStopIsDropped() throws {
        // It arrives after `SessionEnd`; mapping it would resurrect a session
        // that has already closed, as "completed".
        let events = normalizer.normalize(
            grokEnvelope("Stop", payload: try grokFixture("stop-shutdown.json"))
        )
        #expect(events.isEmpty)
    }

    @Test("a tool event carries the tool's name")
    func toolNameIsRead() throws {
        let event = normalizer.normalize(
            grokEnvelope("PreToolUse", payload: try grokFixture("pre-tool-use.json"))
        ).first
        #expect(event?.toolName == "run_terminal_command")
        #expect(event?.summary == "run_terminal_command")
    }

    @Test("a finished turn carries the assistant's last message")
    func stopCarriesBody() throws {
        let event = normalizer.normalize(
            grokEnvelope("Stop", payload: try grokFixture("stop-end-turn.json"))
        ).first
        #expect(event?.detail == "Done - all tests pass.")
    }

    @Test("the user's prompt is the working summary")
    func promptIsSummary() throws {
        let event = normalizer.normalize(
            grokEnvelope("UserPromptSubmit", payload: try grokFixture("user-prompt-submit.json"))
        ).first
        #expect(event?.summary == "Run the tests and tell me what fails")
    }

    @Test("a permission prompt is the only sticky attention state")
    func permissionPromptWaits() {
        // The payload spelling is camelCase; the snake_case rule behind it
        // keeps working if a future build aliases the field, and neither
        // spelling of an idle notification may change state.
        for key in ["notificationType", "notification_type"] {
            let prompt = #"{"session_id":"s","cwd":"/tmp","\#(key)":"permission_prompt"}"#
            #expect(normalizer.normalize(grokEnvelope("Notification", payload: prompt))
                .first?.kind == .waitingApproval, "key \(key)")

            let idle = #"{"session_id":"s","cwd":"/tmp","\#(key)":"idle_prompt"}"#
            #expect(normalizer.normalize(grokEnvelope("Notification", payload: idle)).isEmpty,
                    "key \(key) should not change state")
        }
    }

    @Test("a Stop while a background task runs means still working")
    func stopWithBackgroundTaskIsNotCompletion() {
        let running = #"""
        {"session_id":"s","cwd":"/tmp","reason":"end_turn",
         "backgroundTasks":[{"type":"subagent","status":"running"}]}
        """#
        #expect(normalizer.normalize(grokEnvelope("Stop", payload: running)).first?.kind == .working)

        let finished = #"""
        {"session_id":"s","cwd":"/tmp","reason":"end_turn",
         "backgroundTasks":[{"type":"subagent","status":"completed"}]}
        """#
        #expect(normalizer.normalize(grokEnvelope("Stop", payload: finished)).first?.kind == .completed)
    }

    @Test("an interrupt settles the turn instead of leaving it running")
    func cancelCompletes() {
        let payload = #"{"session_id":"s","cwd":"/tmp","reason":"user_interrupt"}"#
        #expect(normalizer.normalize(grokEnvelope("StopCancelled", payload: payload))
            .first?.kind == .completed)
    }

    @Test("a failed turn is a failure, not a completion")
    func stopFailureIsFailure() {
        let payload = #"{"session_id":"s","cwd":"/tmp","error":"rate_limit"}"#
        #expect(normalizer.normalize(grokEnvelope("StopFailure", payload: payload))
            .first?.kind == .failed)
    }
}
