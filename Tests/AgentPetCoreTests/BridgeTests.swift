import Foundation
import Testing
@testable import AgentPetCore

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func envelope(
    agent: String = "claude-code",
    event: String = "PreToolUse",
    payload: String = #"{"session_id":"s1","cwd":"/tmp/proj","tool_name":"Bash"}"#,
    proc: BridgeProcessInfo? = BridgeProcessInfo(pid: 2, ppid: 1, tty: "/dev/ttys004"),
    version: Int = BridgeEnvelope.currentVersion
) -> BridgeEnvelope {
    BridgeEnvelope(
        agentID: agent,
        eventName: event,
        receivedAt: epoch,
        proc: proc,
        rawPayload: Data(payload.utf8),
        version: version
    )
}

@Suite("Bridge envelope")
struct BridgeEnvelopeTests {

    @Test("an envelope round-trips through the wire")
    func roundTrip() throws {
        let original = envelope()
        let decoded = try BridgeEnvelope.decode(from: original.encoded())
        #expect(decoded == original)
    }

    @Test("the raw payload survives byte for byte")
    func payloadPreserved() throws {
        // Deliberately awkward: non-UTF8 bytes and NUL, which a re-encoding
        // step would mangle.
        let payload = Data([0x00, 0xFF, 0xFE, 0x41, 0x00, 0x42])
        let original = BridgeEnvelope(
            agentID: "claude-code", eventName: "PreToolUse",
            receivedAt: epoch, proc: nil, rawPayload: payload
        )
        let decoded = try BridgeEnvelope.decode(from: original.encoded())
        #expect(decoded.rawPayload == payload)
    }

    @Test("process info round-trips")
    func processInfo() throws {
        let proc = BridgeProcessInfo(pid: 99, ppid: 42, tty: "/dev/ttys001")
        let original = envelope(proc: proc)
        #expect(try BridgeEnvelope.decode(from: original.encoded()).proc == proc)
    }

    @Test("a missing tty is allowed — not every process has a terminal")
    func nilTTY() throws {
        let proc = BridgeProcessInfo(pid: 1, ppid: 2, tty: nil)
        let decoded = try BridgeEnvelope.decode(from: envelope(proc: proc).encoded())
        #expect(decoded.proc?.tty == nil)
    }

    @Test("a future protocol version is refused rather than misread")
    func futureVersionRefused() throws {
        let future = envelope(version: 999)
        #expect(throws: BridgeDecodeError.unsupportedVersion(received: 999, supported: 1)) {
            try BridgeEnvelope.decode(from: future.encoded())
        }
    }

    @Test("a field this build does not know is ignored, not fatal")
    func unknownFieldIgnored() throws {
        let json = #"""
        {"v":1,"shimVersion":"0.1.0","agentID":"claude-code","eventName":"Stop",
         "receivedAt":"2026-09-12T01:00:00Z","rawPayload":"e30=",
         "somethingFromTheFuture":{"nested":true}}
        """#
        let decoded = try BridgeEnvelope.decode(from: Data(json.utf8))
        #expect(decoded.agentID == "claude-code")
    }

    @Test("malformed input is reported as malformed, not as a version problem")
    func malformed() {
        #expect(throws: BridgeDecodeError.self) {
            try BridgeEnvelope.decode(from: Data("not json at all".utf8))
        }
    }

    @Test("a missing required field names the field")
    func missingField() {
        let json = #"{"v":1,"shimVersion":"0.1.0","receivedAt":"2026-09-12T01:00:00Z","rawPayload":"e30="}"#
        #expect(throws: BridgeDecodeError.missingField("agentID")) {
            try BridgeEnvelope.decode(from: Data(json.utf8))
        }
    }

    @Test("an oversized payload is refused")
    func oversizedPayload() throws {
        let huge = Data(repeating: 0x41, count: BridgeEnvelope.maximumPayloadBytes + 1)
        let original = BridgeEnvelope(
            agentID: "claude-code", eventName: "PreToolUse",
            receivedAt: epoch, proc: nil, rawPayload: huge
        )
        #expect(throws: BridgeDecodeError.self) {
            try BridgeEnvelope.decode(from: original.encoded())
        }
    }

    @Test("an empty payload is fine")
    func emptyPayload() throws {
        let original = envelope(payload: "")
        let decoded = try BridgeEnvelope.decode(from: original.encoded())
        #expect(decoded.rawPayload.isEmpty)
    }
}

@Suite("Claude Code normalization")
struct ClaudeCodeNormalizationTests {

    private let normalizer = EventNormalizer(profiles: AgentProfiles.all)

    @Test("hook events map to normalized kinds", arguments: [
        ("SessionStart", AgentEventKind.sessionStarted),
        ("UserPromptSubmit", .working),
        ("PreToolUse", .working),
        ("PostToolUse", .working),
        ("PermissionRequest", .waitingApproval),
        ("StopFailure", .failed),
        ("SubagentStart", .working),
        ("TaskCompleted", .completed),
        ("PostCompact", .working),
        ("Stop", .completed),
        ("SubagentStop", .working),
        ("PreCompact", .working),
        ("SessionEnd", .sessionClosed),
    ])
    func eventMapping(event: String, kind: AgentEventKind) throws {
        let events = normalizer.normalize(envelope(event: event))
        #expect(events.count == 1)
        #expect(events.first?.kind == kind)
    }

    @Test("a subagent finishing is not the session finishing")
    func subagentStopIsNotCompletion() {
        let events = normalizer.normalize(envelope(event: "SubagentStop"))
        #expect(events.first?.kind == .working)
    }

    @Test("permission requests are the only sticky attention state")
    func permissionRequestIsTheApprovalSignal() {
        let request = normalizer.normalize(envelope(event: "PermissionRequest"))
        #expect(request.first?.kind == .waitingApproval)

        // The same signal arrives through Notification on some builds.
        let notified = normalizer.normalize(envelope(
            event: "Notification",
            payload: #"{"session_id":"s","cwd":"/tmp","notification_type":"permission_prompt"}"#
        ))
        #expect(notified.first?.kind == .waitingApproval)
    }

    @Test("an informational notification changes nothing")
    func idleNotificationIsIgnored() {
        // Reporting this as "waiting for input" is what left the pet asking for
        // attention forever once more than one session was open.
        for kind in ["idle_prompt", "auth_success", "elicitation_dialog"] {
            let events = normalizer.normalize(envelope(
                event: "Notification",
                payload: #"{"session_id":"s","cwd":"/tmp","notification_type":"\#(kind)"}"#
            ))
            #expect(events.isEmpty, "notification_type \(kind) should not change state")
        }
    }

    @Test("a bare Notification with no type changes nothing")
    func untypedNotificationIgnored() {
        #expect(normalizer.normalize(envelope(event: "Notification", payload: "{}")).isEmpty)
    }

    @Test("a Stop while a background subagent runs means still working")
    func stopWithBackgroundTaskIsNotCompletion() {
        let running = """
        {"session_id":"s","cwd":"/tmp",
         "background_tasks":[{"type":"subagent","status":"running"}]}
        """
        let events = normalizer.normalize(envelope(event: "Stop", payload: running))
        #expect(events.first?.kind == .working,
                "announcing completion mid-job is worse than saying nothing")
    }

    @Test("a Stop with no running background task is a finished turn")
    func stopWithoutBackgroundTaskCompletes() {
        let finished = """
        {"session_id":"s","cwd":"/tmp",
         "background_tasks":[{"type":"subagent","status":"completed"}]}
        """
        #expect(normalizer.normalize(envelope(event: "Stop", payload: finished)).first?.kind == .completed)
        #expect(normalizer.normalize(envelope(event: "Stop", payload: "{}")).first?.kind == .completed)
    }

    @Test("a Stop carries the assistant's last message as the pet's second line")
    func stopCarriesPreview() {
        // The message contains JSON escapes on purpose: real payloads carry
        // newlines inside the string, not as literal line breaks.
        let payload = """
        {"session_id":"s","cwd":"/tmp","stop_hook_active":false,
         "last_assistant_message":"  Fixed the   flaky test.\\n\\nIt was a race.  "}
        """
        let event = normalizer.normalize(envelope(event: "Stop", payload: payload)).first

        #expect(event?.kind == .completed)
        #expect(event?.detail == "Fixed the flaky test. It was a race.",
                "whitespace is collapsed, the way Codex tidies its preview")
    }

    @Test("a preview is cut to Codex's two hundred characters")
    func previewIsBounded() {
        let long = String(repeating: "ab", count: 300)
        let event = normalizer.normalize(envelope(
            event: "Stop", payload: #"{"session_id":"s","last_assistant_message":"\#(long)"}"#
        )).first
        #expect(event?.detail?.count == 200)
    }

    @Test("no preview when the agent sends none, and none for other events")
    func previewOnlyWhereItExists() {
        #expect(normalizer.normalize(envelope(event: "Stop", payload: "{}")).first?.detail == nil)
        // A tool event has nothing to preview even if a payload planted one.
        let planted = #"{"session_id":"s","tool_name":"Bash","last_assistant_message":"hi"}"#
        #expect(normalizer.normalize(envelope(event: "PreToolUse", payload: planted)).first?.detail == nil)
    }

    @Test("session id and working directory are extracted")
    func fieldExtraction() {
        let events = normalizer.normalize(envelope(
            payload: #"{"session_id":"abc-123","cwd":"/Users/x/proj","tool_name":"Edit"}"#
        ))
        #expect(events.first?.sessionID == "abc-123")
        #expect(events.first?.projectPath?.path == "/Users/x/proj")
        #expect(events.first?.summary == "Edit")
    }

    @Test("the working directory becomes an openable focus target")
    func focusTarget() {
        let events = normalizer.normalize(envelope(payload: #"{"session_id":"s","cwd":"/tmp/p"}"#))
        #expect(events.first?.focusTarget?.kind == .directory)
        #expect(events.first?.focusTarget?.path == "/tmp/p")
    }

    @Test("a payload with no cwd yields an unusable focus target, not a bogus one")
    func noFocusWithoutCwd() {
        let events = normalizer.normalize(envelope(payload: #"{"session_id":"s"}"#))
        #expect(events.first?.focusTarget?.kind == FocusTarget.Kind.none)
    }

    @Test("confidence records which hook produced the event")
    func confidenceSource() {
        let events = normalizer.normalize(envelope(event: "PreToolUse"))
        #expect(events.first?.confidence.level == .high)
        #expect(events.first?.confidence.source == "claude-code.hook.PreToolUse")
    }
}

@Suite("Normalization robustness")
struct NormalizationRobustnessTests {

    private let normalizer = EventNormalizer(profiles: AgentProfiles.all)

    @Test("an unknown agent is ignored rather than fatal")
    func unknownAgent() {
        #expect(normalizer.normalize(envelope(agent: "some-future-agent")).isEmpty)
    }

    @Test("an unlisted event name is ignored")
    func unknownEvent() {
        #expect(normalizer.normalize(envelope(event: "SomethingNew")).isEmpty)
    }

    @Test("a payload that is not JSON still produces an event")
    func nonJSONPayload() {
        // Some hooks pass plain text. The transport must not care.
        let events = normalizer.normalize(envelope(event: "Stop", payload: "plain text, not json"))
        #expect(events.count == 1)
        #expect(events.first?.kind == .completed)
    }

    @Test("an empty payload still produces an event")
    func emptyPayload() {
        let events = normalizer.normalize(envelope(event: "Stop", payload: ""))
        #expect(events.count == 1)
    }

    @Test("a payload with no session id falls back to the agent's process id")
    func fallbackSessionUsesParentProcess() {
        // ppid is the agent. Two terminals running the same agent are two
        // processes, so this keeps them apart where a constant would merge them.
        let proc = BridgeProcessInfo(pid: 500, ppid: 4242, tty: "/dev/ttys003")
        let events = normalizer.normalize(envelope(payload: #"{"tool_name":"Bash"}"#, proc: proc))
        #expect(events.count == 1)
        #expect(events.first?.sessionID == "ppid-4242")
    }

    @Test("two sessions of one agent stay distinct without session ids")
    func concurrentSessionsStayApart() {
        let a = normalizer.normalize(envelope(
            payload: #"{"tool_name":"Bash"}"#,
            proc: BridgeProcessInfo(pid: 1, ppid: 100, tty: nil)
        ))
        let b = normalizer.normalize(envelope(
            payload: #"{"tool_name":"Bash"}"#,
            proc: BridgeProcessInfo(pid: 2, ppid: 200, tty: nil)
        ))
        #expect(a.first?.sessionID != b.first?.sessionID)
    }

    @Test("with no process information at all, the profile's constant is used")
    func fallbackWithoutProcess() {
        let events = normalizer.normalize(envelope(payload: #"{"tool_name":"Bash"}"#, proc: nil))
        #expect(events.first?.sessionID == "default")
    }

    @Test("a numeric session id is coerced rather than discarded")
    func numericSessionID() {
        let events = normalizer.normalize(envelope(payload: #"{"session_id":12345}"#))
        #expect(events.first?.sessionID == "12345")
    }

    @Test("Grok shares Claude Code's hook vocabulary")
    func grokProfile() throws {
        let events = normalizer.normalize(envelope(agent: "grok", event: "PermissionRequest"))
        #expect(events.first?.kind == .waitingApproval)
    }

    @Test("process observation is reported at lower confidence than a hook")
    func genericCLIConfidence() {
        let events = normalizer.normalize(envelope(
            agent: "generic-cli", event: "process-active", payload: ""
        ))
        #expect(events.first?.confidence.level == .low)
    }

    @Test("every profile's rules point at real event kinds")
    func profilesAreWellFormed() {
        for profile in AgentProfiles.all {
            #expect(!profile.rules.isEmpty, "\(profile.agentID) has no rules")
            for rule in profile.rules {
                #expect(!rule.matches.isEmpty, "\(profile.agentID) has an empty match list")
            }
        }
    }

    @Test("no profile maps two different events to conflicting ids")
    func agentIDsUnique() {
        let ids = AgentProfiles.all.map(\.agentID)
        #expect(Set(ids).count == ids.count)
    }

    @Test("a normalized event drives the activity engine end to end")
    func endToEndIntoEngine() {
        let clock = ManualActivityClock(epoch)
        let engine = ActivityEngine(clock: clock)

        // Checked immediately: `completed` now settles after four seconds, so
        // advancing the clock first would see the settled state rather than the
        // transition under test.
        for (event, expected) in [("PreToolUse", AgentState.running),
                                  ("PermissionRequest", AgentState.waitingApproval),
                                  ("Stop", AgentState.completed)] {
            for agentEvent in normalizer.normalize(envelope(event: event)) {
                engine.ingest(agentEvent)
            }
            #expect(engine.currentFocus()?.state == expected, "after \(event)")
            clock.advance(by: 1)
        }

        // And the celebration does not stick.
        clock.advance(by: 10)
        #expect(engine.currentFocus()?.state == .idle, "a finished turn should settle to idle")
    }
}

@Suite("Bridge accept failures")
struct BridgeAcceptFailureTests {

    @Test("a connection that failed is not a listener that failed", arguments: [
        EINTR, ECONNABORTED, EPROTO,
    ])
    func connectionFailuresRetryImmediately(code: Int32) {
        #expect(BridgeServer.acceptFailure(for: code) == .retryNow)
    }

    @Test("running out of descriptors is survivable", arguments: [EMFILE, ENFILE])
    func descriptorExhaustionBacksOff(code: Int32) {
        // The regression this exists for: the accept loop treated every error
        // as "the socket was closed" and ended, so one burst of connections
        // that filled the descriptor table left a bridge that still reported
        // itself as listening and never delivered another event.
        #expect(BridgeServer.acceptFailure(for: code) == .outOfDescriptors)
    }

    @Test("a socket that is genuinely gone ends the loop", arguments: [EBADF, EINVAL, ENOTSOCK])
    func unusableSocketsStop(code: Int32) {
        #expect(BridgeServer.acceptFailure(for: code) == .fatal)
    }

    @Test("a server that never started is not accepting")
    func notStartedIsNotAccepting() {
        let server = BridgeServer(
            socketURL: URL(fileURLWithPath: "/tmp/ap-never-\(getpid()).sock"),
            handler: { _ in }
        )
        #expect(!server.isAccepting, "the menu must not say Listening for a bridge that never ran")
    }
}
