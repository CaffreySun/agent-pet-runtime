import Foundation
import Testing
@testable import AgentPetCore

private func piEnvelope(_ event: String, payload: String) -> BridgeEnvelope {
    BridgeEnvelope(
        agentID: "pi",
        eventName: event,
        receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
        proc: BridgeProcessInfo(pid: 100, ppid: 50, tty: nil),
        rawPayload: Data(payload.utf8)
    )
}

@Suite("Pi normalization (the extension's contract)")
struct PiNormalizationTests {

    private let normalizer = EventNormalizer(profiles: AgentProfiles.all)

    @Test("the events the extension sends map to the right kinds", arguments: [
        ("session_start", AgentEventKind.sessionStarted),
        ("agent_start", .working),
        ("tool_execution_start", .working),
        ("ui_prompt_start", .waitingInput),
        ("agent_settled", .completed),
        ("session_shutdown", .sessionClosed),
    ])
    func eventMapping(event: String, kind: AgentEventKind) {
        let payload = #"{"session_id":"s1","cwd":"/tmp/proj"}"#
        let events = normalizer.normalize(piEnvelope(event, payload: payload))
        #expect(events.first?.kind == kind)
        #expect(events.first?.sessionID == "s1")
    }

    @Test("a tool start carries the tool's name")
    func toolName() {
        let payload = #"{"session_id":"s1","cwd":"/tmp/proj","toolName":"bash"}"#
        let event = normalizer.normalize(piEnvelope("tool_execution_start", payload: payload)).first
        #expect(event?.kind == .working)
        #expect(event?.toolName == "bash")
    }

    @Test("the legacy agent_end is not a settle")
    func agentEndIsNotASettle() {
        // The extension reports `agent_settled` only: after `agent_end`, Pi
        // may still auto-retry or run queued follow-ups, so announcing
        // completion there would celebrate mid-job.
        #expect(normalizer.normalize(piEnvelope("agent_end", payload: #"{"session_id":"s1"}"#)).isEmpty)
    }

    @Test("a context reading arrives as a description, not a state change")
    func contextReading() {
        let payload = """
        {"session_id":"s1","tokens":88244,"window":1048576,
         "used_percentage":8.4,"model":"claude-opus-5"}
        """
        let event = normalizer.normalize(piEnvelope("context_update", payload: payload)).first
        #expect(event?.kind == .contextUpdate)
        #expect(event?.context?.usedPercent == 8.4)
        #expect(event?.context?.modelName == "claude-opus-5")
    }
}
