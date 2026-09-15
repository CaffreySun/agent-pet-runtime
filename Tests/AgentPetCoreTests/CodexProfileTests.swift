import Foundation
import Testing
@testable import AgentPetCore

/// Payloads shaped after Codex's own wire structs (read out of the installed
/// 0.153.4 binary, 2026-09-15): Claude-shaped JSON with `session_id`,
/// `hook_event_name`, `model`, `permission_mode`, and the `tool_*` fields.
/// No live capture exists yet — Codex skips untrusted hooks, and trusting is
/// a one-time step only the user can do.
private func codexEnvelope(_ event: String, payload: String) -> BridgeEnvelope {
    BridgeEnvelope(
        agentID: "codex",
        eventName: event,
        receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
        proc: BridgeProcessInfo(pid: 100, ppid: 50, tty: "/dev/ttys001"),
        rawPayload: Data(payload.utf8)
    )
}

@Suite("Codex normalization (binary-verified wire shape)")
struct CodexNormalizationTests {

    private let normalizer = EventNormalizer(profiles: AgentProfiles.all)
    private let base = #"{"session_id":"s1","cwd":"/tmp/proj","model":"gpt-5.6","permission_mode":"default"}"#

    @Test("hook events map to normalized kinds", arguments: [
        ("SessionStart", AgentEventKind.sessionStarted),
        ("UserPromptSubmit", .working),
        ("PreToolUse", .working),
        ("PostToolUse", .working),
        ("PermissionRequest", .waitingApproval),
        ("SubagentStart", .working),
        ("SubagentStop", .working),
        ("PreCompact", .working),
        ("PostCompact", .working),
        ("Stop", .completed),
        ("Interrupt", .completed),
        ("SessionEnd", .sessionClosed),
    ])
    func eventMapping(event: String, kind: AgentEventKind) {
        let events = normalizer.normalize(codexEnvelope(event, payload: base))
        #expect(events.first?.kind == kind)
        #expect(events.first?.sessionID == "s1")
    }

    @Test("events Codex does not have change nothing")
    func alienEventsChangeNothing() {
        for event in ["Notification", "TaskCompleted", "StopFailure"] {
            #expect(normalizer.normalize(codexEnvelope(event, payload: base)).isEmpty,
                    "\(event) is Claude Code's; Codex never fires it")
        }
    }

    @Test("a permission request names the tool it is waiting on")
    func permissionRequestNamesTool() {
        let payload = #"{"session_id":"s1","cwd":"/tmp/proj","tool_name":"Bash"}"#
        let event = normalizer.normalize(codexEnvelope("PermissionRequest", payload: payload)).first
        #expect(event?.kind == .waitingApproval)
        #expect(event?.toolName == "Bash")
    }

    @Test("an interrupt settles the turn instead of leaving it running")
    func interruptSettles() {
        #expect(normalizer.normalize(codexEnvelope("Interrupt", payload: base))
            .first?.kind == .completed)
    }

    @Test("a Stop carries the last message when the field is there")
    func stopPreviewWhenPresent() {
        let payload = #"{"session_id":"s1","cwd":"/tmp/proj","last_assistant_message":"Fixed it."}"#
        let with = normalizer.normalize(codexEnvelope("Stop", payload: payload)).first
        #expect(with?.detail == "Fixed it.")

        // And when it is not — the documented shape does not promise it.
        let without = normalizer.normalize(codexEnvelope("Stop", payload: base)).first
        #expect(without?.kind == .completed)
        #expect(without?.detail == nil)
    }
}
