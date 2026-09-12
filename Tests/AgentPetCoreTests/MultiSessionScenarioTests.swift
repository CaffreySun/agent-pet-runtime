import Foundation
import Testing
@testable import AgentPetCore

/// Reproduces the situation that prompted this work: several Claude Code
/// sessions open at once, and the pet stuck showing "waiting for input" with no
/// way to tell whether that was right.
///
/// These run end to end through the normalizer and the engine, with payloads
/// shaped like the ones Claude Code 2.1.268 actually sends.
@Suite("Multiple concurrent agent sessions")
struct MultiSessionScenarioTests {

    private let normalizer = EventNormalizer(profiles: AgentProfiles.all)
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func envelope(
        _ event: String,
        session: String,
        at offset: TimeInterval = 0,
        extra: [String: Any] = [:]
    ) -> BridgeEnvelope {
        var payload: [String: Any] = [
            "session_id": session,
            "cwd": "/Users/someone/project",
            "hook_event_name": event,
        ]
        payload.merge(extra) { _, new in new }

        return BridgeEnvelope(
            agentID: "claude-code",
            eventName: event,
            receivedAt: origin.addingTimeInterval(offset),
            proc: BridgeProcessInfo(pid: 100, ppid: 50, tty: nil),
            rawPayload: (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        )
    }

    private func makeEngine() -> (ActivityEngine, ManualActivityClock) {
        let clock = ManualActivityClock(origin)
        return (ActivityEngine(clock: clock), clock)
    }

    private func feed(_ engine: ActivityEngine, _ envelope: BridgeEnvelope) {
        for event in normalizer.normalize(envelope) { engine.ingest(event) }
    }

    // MARK: - The reported symptom

    @Test("an idle notification does not leave the pet asking for attention forever")
    func idleNotificationDoesNotStick() {
        let (engine, clock) = makeEngine()

        feed(engine, envelope("UserPromptSubmit", session: "a"))
        #expect(engine.currentFocus()?.state == .running)

        // Claude has been quiet a while and reminds the user. This used to map
        // to a state that never expired, which is what pinned the pet on
        // "waiting for input" whenever more than one session was open.
        clock.advance(by: 5)
        feed(engine, envelope("Notification", session: "a", at: 5,
                              extra: ["notification_type": "idle_prompt"]))

        #expect(engine.currentFocus()?.state == .running,
                "an informational notification must not change the state")

        clock.advance(by: 60)
        #expect(engine.currentFocus()?.state != .waitingInput,
                "the pet must never be stuck waiting because of a reminder")
    }

    @Test("two finished sessions settle to idle rather than queueing up as attention")
    func severalFinishedSessionsSettle() {
        let (engine, clock) = makeEngine()

        feed(engine, envelope("UserPromptSubmit", session: "a"))
        feed(engine, envelope("UserPromptSubmit", session: "b", at: 1))

        clock.advance(by: 10)
        feed(engine, envelope("Stop", session: "a", at: 10))
        feed(engine, envelope("Stop", session: "b", at: 11))

        clock.advance(by: 6)   // past the completion dwell
        #expect(engine.currentFocus()?.state == .idle)
        #expect(engine.allActivities().allSatisfy { $0.state == .idle },
                "every finished session should have settled")
    }

    // MARK: - The one state worth holding

    @Test("a permission request holds, because the agent cannot proceed without you")
    func permissionRequestHolds() {
        let (engine, clock) = makeEngine()

        feed(engine, envelope("UserPromptSubmit", session: "a"))
        feed(engine, envelope("UserPromptSubmit", session: "b", at: 1))

        clock.advance(by: 10)
        feed(engine, envelope("PermissionRequest", session: "a", at: 10,
                              extra: ["tool_name": "Bash"]))

        #expect(engine.currentFocus()?.state == .waitingApproval)
        #expect(engine.currentFocus()?.sessionID == "a")

        // It keeps holding while the other session carries on.
        clock.advance(by: 20)
        feed(engine, envelope("PreToolUse", session: "b", at: 30,
                              extra: ["tool_name": "Read"]))
        #expect(engine.currentFocus()?.state == .waitingApproval,
                "a blocked session outranks a working one")

        // And it is released when the user answers.
        clock.advance(by: 5)
        feed(engine, envelope("PreToolUse", session: "a", at: 35,
                              extra: ["tool_name": "Bash"]))
        #expect(engine.currentFocus()?.state == .running)
    }

    @Test("an approval left unanswered eventually stops holding")
    func unansweredApprovalExpires() {
        let (engine, clock) = makeEngine()
        feed(engine, envelope("PermissionRequest", session: "a"))
        #expect(engine.currentFocus()?.state == .waitingApproval)

        clock.advance(by: 301)
        #expect(engine.currentFocus()?.state != .waitingApproval,
                "a five-minute-old prompt is more likely gone than pending")
    }

    // MARK: - Sessions stay separate

    @Test("concurrent sessions never merge into one")
    func sessionsStayDistinct() {
        let (engine, _) = makeEngine()
        for (index, session) in ["a", "b", "c"].enumerated() {
            feed(engine, envelope("UserPromptSubmit", session: session, at: TimeInterval(index)))
        }
        #expect(engine.allActivities().count == 3)
        #expect(Set(engine.allActivities().map(\.sessionID)) == ["a", "b", "c"])
    }

    @Test("one session finishing leaves another session's work alone")
    func finishingOneDoesNotDisturbAnother() {
        let (engine, clock) = makeEngine()
        feed(engine, envelope("UserPromptSubmit", session: "a"))
        feed(engine, envelope("UserPromptSubmit", session: "b", at: 1))

        clock.advance(by: 10)
        feed(engine, envelope("Stop", session: "a", at: 10))

        clock.advance(by: 6)
        let b = engine.activity(for: SessionKey(agentID: "claude-code", sessionID: "b"))
        #expect(b?.state == .running, "session b was still working")
    }

    @Test("a subagent finishing does not report the session as finished")
    func subagentStopDoesNotFinishSession() {
        let (engine, _) = makeEngine()
        feed(engine, envelope("UserPromptSubmit", session: "a"))
        feed(engine, envelope("SubagentStart", session: "a", at: 1))
        feed(engine, envelope("SubagentStop", session: "a", at: 2))
        #expect(engine.currentFocus()?.state == .running)
    }

    @Test("a paused turn with a background subagent is not announced as finished")
    func backgroundSubagentSuppressesCompletion() {
        let (engine, _) = makeEngine()
        feed(engine, envelope("UserPromptSubmit", session: "a"))

        feed(engine, envelope("Stop", session: "a", at: 1, extra: [
            "background_tasks": [["type": "subagent", "status": "running"]],
        ]))
        #expect(engine.currentFocus()?.state == .running,
                "the job is still running; announcing completion would be a lie")

        // Once it really finishes, the stop counts.
        feed(engine, envelope("Stop", session: "a", at: 2, extra: [
            "background_tasks": [["type": "subagent", "status": "completed"]],
        ]))
        #expect(engine.currentFocus()?.state == .completed)
    }

    @Test("a failed turn is distinguishable from a finished one")
    func failureIsDistinct() {
        let (engine, _) = makeEngine()
        feed(engine, envelope("UserPromptSubmit", session: "a"))
        feed(engine, envelope("StopFailure", session: "a", at: 1,
                              extra: ["error": "context limit"]))
        #expect(engine.currentFocus()?.state == .failed)
    }

    @Test("a whole trace with several sessions ends in a sensible state")
    func realisticTrace() {
        let (engine, clock) = makeEngine()

        // Two sessions start and get to work.
        feed(engine, envelope("SessionStart", session: "a"))
        feed(engine, envelope("UserPromptSubmit", session: "a", at: 1))
        feed(engine, envelope("SessionStart", session: "b", at: 1))
        feed(engine, envelope("UserPromptSubmit", session: "b", at: 2))
        feed(engine, envelope("PreToolUse", session: "a", at: 3, extra: ["tool_name": "Bash"]))
        feed(engine, envelope("PostToolUse", session: "a", at: 4, extra: ["tool_name": "Bash"]))

        // b wants permission.
        clock.advance(by: 5)
        feed(engine, envelope("PermissionRequest", session: "b", at: 10,
                              extra: ["tool_name": "Write"]))
        #expect(engine.currentFocus()?.state == .waitingApproval,
                "the blocked session is what the user needs to see")

        // The user answers; b works and finishes.
        clock.advance(by: 5)
        feed(engine, envelope("PostToolUse", session: "b", at: 15, extra: ["tool_name": "Write"]))
        clock.advance(by: 5)
        feed(engine, envelope("Stop", session: "b", at: 20))

        // a finishes too.
        clock.advance(by: 5)
        feed(engine, envelope("Stop", session: "a", at: 25))

        clock.advance(by: 10)
        #expect(engine.currentFocus()?.state == .idle)
        #expect(engine.allActivities().count == 2, "both sessions should still be open")
    }
}
