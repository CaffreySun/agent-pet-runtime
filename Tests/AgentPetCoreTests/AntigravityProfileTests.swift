import Foundation
import Testing
@testable import AgentPetCore

/// Payloads captured from a real Antigravity CLI 1.2.3 session on 2026-09-15
/// (this machine, one tool-using turn), reduced to synthetic values. The
/// `SessionStart` fixture is the undocumented event the binary's own doc
/// table omits; `PostToolUse` has no fixture on purpose — it was registered
/// and never fired.
private func antigravityFixture(_ name: String) throws -> String {
    let stem = name.hasSuffix(".json") ? String(name.dropLast(".json".count)) : name
    let url = Bundle.module.url(
        forResource: "Fixtures/antigravity/\(stem)",
        withExtension: "json"
    )
    guard let url else {
        Issue.record("missing fixture \(name).json")
        throw NormalizationError.notJSON
    }
    return try String(contentsOf: url, encoding: .utf8)
}

private func antigravityEnvelope(_ event: String, payload: String) -> BridgeEnvelope {
    BridgeEnvelope(
        agentID: "antigravity",
        eventName: event,
        receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
        proc: BridgeProcessInfo(pid: 100, ppid: 50, tty: nil),
        rawPayload: Data(payload.utf8)
    )
}

@Suite("Antigravity normalization (captured payloads)")
struct AntigravityNormalizationTests {

    private let normalizer = EventNormalizer(profiles: AgentProfiles.all)
    private let session = "aaaa1111-2222-4333-8444-555555555555"

    @Test("captured wire payloads map to the right kinds", arguments: [
        ("session-start.json", "SessionStart", AgentEventKind.sessionStarted),
        ("pre-invocation.json", "PreInvocation", .working),
        ("post-invocation.json", "PostInvocation", .working),
        ("pre-tool-use.json", "PreToolUse", .working),
        ("stop.json", "Stop", .completed),
    ])
    func capturedPayloads(file: String, event: String, kind: AgentEventKind) throws {
        let events = normalizer.normalize(
            antigravityEnvelope(event, payload: try antigravityFixture(file))
        )
        #expect(events.count == 1)
        #expect(events.first?.kind == kind)
        #expect(events.first?.sessionID == session, "the conversationId must be read")
    }

    @Test("a tool event carries the tool's name from the nested call")
    func toolNameIsRead() throws {
        let event = normalizer.normalize(
            antigravityEnvelope("PreToolUse", payload: try antigravityFixture("pre-tool-use.json"))
        ).first
        #expect(event?.toolName == "run_command", "toolCall.name is nested; the reader walks dots")
        #expect(event?.summary == "run_command")
    }

    @Test("an error stop is a failure, and only a non-empty error says so")
    func errorStopFails() {
        let clean = #"{"conversationId":"c1","error":"","fullyIdle":true}"#
        #expect(normalizer.normalize(antigravityEnvelope("Stop", payload: clean))
            .first?.kind == .completed)

        let failed = #"{"conversationId":"c1","error":"model exploded","fullyIdle":true}"#
        let event = normalizer.normalize(antigravityEnvelope("Stop", payload: failed)).first
        #expect(event?.kind == .failed)
        #expect(event?.summary == "model exploded")
    }

    @Test("a stop with background work still running is still working")
    func busyStopIsWorking() {
        let busy = #"{"conversationId":"c1","error":"","fullyIdle":false}"#
        #expect(normalizer.normalize(antigravityEnvelope("Stop", payload: busy))
            .first?.kind == .working)
    }

    @Test("an error outranks a busy flag")
    func errorBeatsBusy() {
        let both = #"{"conversationId":"c1","error":"boom","fullyIdle":false}"#
        #expect(normalizer.normalize(antigravityEnvelope("Stop", payload: both))
            .first?.kind == .failed)
    }

    @Test("the workspace array reads as its first entry")
    func workspaceArrayReads() {
        let payload = #"{"conversationId":"c1","workspacePaths":["/home/dev/proj"]}"#
        let event = normalizer.normalize(antigravityEnvelope("PreInvocation", payload: payload)).first
        #expect(event?.projectPath?.path == "/home/dev/proj")
    }

    @Test("an event Antigravity does not have changes nothing")
    func alienEventsChangeNothing() {
        // There is no waiting-for-input signal to map, and Notification is
        // not part of this vocabulary.
        for event in ["Notification", "UserPromptSubmit", "PermissionRequest"] {
            #expect(normalizer.normalize(antigravityEnvelope(event, payload: #"{"conversationId":"c1"}"#))
                .isEmpty, "\(event) does not exist in Antigravity's vocabulary")
        }
    }
}
