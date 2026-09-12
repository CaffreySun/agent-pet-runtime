import Foundation
import Testing
@testable import AgentPetCore

private let start = Date(timeIntervalSince1970: 1_700_000_000)

private func event(
    _ kind: AgentEventKind,
    agent: String = "claude-code",
    session: String = "s1",
    at: Date = start,
    summary: String? = nil,
    focus: FocusTarget? = nil,
    id: String? = nil
) -> AgentEvent {
    AgentEvent(
        agentID: agent,
        sessionID: session,
        kind: kind,
        at: at,
        confidence: EventConfidence(level: .high, source: "test"),
        summary: summary,
        focusTarget: focus,
        eventID: id
    )
}

private func makeEngine(_ tuning: ActivityTuning = .default)
    -> (ActivityEngine, ManualActivityClock)
{
    let clock = ManualActivityClock(start)
    return (ActivityEngine(tuning: tuning, clock: clock), clock)
}

@Suite("ActivityEngine — session lifecycle")
struct ActivityLifecycleTests {

    @Test("an unknown session produces nothing to show")
    func emptyEngine() {
        let (engine, _) = makeEngine()
        #expect(engine.currentFocus() == nil)
        #expect(engine.allActivities().isEmpty)
    }

    @Test("a working event creates a running activity")
    func workingCreatesActivity() {
        let (engine, _) = makeEngine()
        engine.ingest(event(.working))
        let focus = engine.currentFocus()
        #expect(focus?.state == .running)
        #expect(focus?.agentID == "claude-code")
        #expect(focus?.sessionID == "s1")
    }

    @Test("sessionClosed removes the activity entirely")
    func sessionClosedRemoves() {
        let (engine, _) = makeEngine()
        engine.ingest(event(.working))
        #expect(engine.allActivities().count == 1)
        engine.ingest(event(.sessionClosed, at: start.addingTimeInterval(1)))
        #expect(engine.allActivities().isEmpty)
        #expect(engine.currentFocus() == nil)
    }

    @Test("the same session never yields two activities")
    func sessionDeduplication() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working))
        clock.advance(by: 1); engine.ingest(event(.working, at: clock.now))
        clock.advance(by: 1); engine.ingest(event(.waitingInput, at: clock.now))
        clock.advance(by: 1); engine.ingest(event(.working, at: clock.now))
        #expect(engine.allActivities().count == 1)
    }

    @Test("two agents on the same session string stay separate")
    func agentIsPartOfTheKey() {
        let (engine, _) = makeEngine()
        engine.ingest(event(.working, agent: "claude-code", session: "shared"))
        engine.ingest(event(.working, agent: "codex", session: "shared"))
        #expect(engine.allActivities().count == 2)
    }

    @Test("the activity id is agent-qualified")
    func activityID() {
        let (engine, _) = makeEngine()
        engine.ingest(event(.working, agent: "codex", session: "abc"))
        #expect(engine.allActivities().first?.id == "codex/abc")
    }
}

@Suite("ActivityEngine — state transitions")
struct ActivityTransitionTests {

    @Test("a later event advances the state")
    func advances() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working))
        clock.advance(by: 5)
        engine.ingest(event(.waitingApproval, at: clock.now))
        #expect(engine.currentFocus()?.state == .waitingApproval)
    }

    @Test("events that do not change state preserve the aging clock")
    func repeatedStateKeepsEnteredAt() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.failed))
        clock.advance(by: 30)
        engine.ingest(event(.failed, at: clock.now))
        clock.advance(by: 30)
        engine.ingest(event(.failed, at: clock.now))

        let activity = engine.allActivities()[0]
        #expect(activity.enteredStateAt == start)
        #expect(activity.updatedAt == clock.now)
    }

    @Test("changing state resets the aging clock")
    func stateChangeResetsEnteredAt() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working))
        clock.advance(by: 40)
        engine.ingest(event(.failed, at: clock.now))
        #expect(engine.allActivities()[0].enteredStateAt == clock.now)
    }

    @Test("an out-of-order event is dropped rather than rewinding the session")
    func outOfOrderDropped() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.waitingInput))
        clock.advance(by: 10)
        engine.ingest(event(.waitingInput, at: clock.now))
        let droppedBefore = engine.droppedEventCount

        engine.ingest(event(.working, at: start))   // stale timestamp
        #expect(engine.allActivities()[0].state == .waitingInput)
        #expect(engine.droppedEventCount == droppedBefore + 1)
    }

    @Test("sessionStarted lands on idle, not running")
    func sessionStartedIsIdle() {
        let (engine, _) = makeEngine()
        engine.ingest(event(.sessionStarted))
        #expect(engine.allActivities()[0].state == .idle)
    }

    @Test("a focus target survives a later event that lacks one")
    func focusTargetSticky() {
        let (engine, clock) = makeEngine()
        let target = FocusTarget.openingDirectory(URL(fileURLWithPath: "/tmp/proj"))
        engine.ingest(event(.working, focus: target))
        clock.advance(by: 1)
        engine.ingest(event(.waitingInput, at: clock.now))
        #expect(engine.allActivities()[0].focusTarget == target)
    }
}

@Suite("ActivityEngine — deduplication")
struct ActivityDedupeTests {

    @Test("an identical event inside the window is dropped")
    func identicalEventDropped() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working))
        clock.advance(by: 0.1)
        engine.ingest(event(.working, at: clock.now))
        #expect(engine.droppedEventCount == 1)
    }

    @Test("the same event outside the window is accepted")
    func outsideWindowAccepted() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working))
        clock.advance(by: 1.0)
        engine.ingest(event(.working, at: clock.now))
        #expect(engine.droppedEventCount == 0)
    }

    @Test("a differing explicit event id is a distinct event")
    func explicitIDsDistinguish() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working, id: "a"))
        clock.advance(by: 0.01)
        engine.ingest(event(.working, at: clock.now, id: "b"))
        #expect(engine.droppedEventCount == 0)
    }

    @Test("a repeated explicit event id is a duplicate however far apart")
    func repeatedIDDropped() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working, id: "a"))
        clock.advance(by: 60)
        engine.ingest(event(.working, at: clock.now, id: "a"))
        #expect(engine.droppedEventCount == 1)
    }
}

@Suite("ActivityEngine — priority")
struct ActivityPriorityTests {

    @Test("a blocking session outranks a working one")
    func attentionBeatsActive() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working, agent: "codex", session: "a"))
        clock.advance(by: 10)   // long enough that focus hold has expired
        engine.ingest(event(.waitingInput, agent: "claude-code", session: "b", at: clock.now))
        clock.advance(by: 10)
        #expect(engine.currentFocus()?.agentID == "claude-code")
    }

    @Test("waitingInput outranks waitingApproval within the attention class")
    func waitingInputRanksFirst() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.waitingApproval, agent: "codex", session: "a"))
        clock.advance(by: 20)
        engine.ingest(event(.waitingInput, agent: "claude-code", session: "b", at: clock.now))
        clock.advance(by: 20)
        #expect(engine.currentFocus()?.state == .waitingInput)
    }

    @Test("within a class the earlier arrival wins")
    func earlierWins() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.waitingInput, agent: "codex", session: "a"))
        clock.advance(by: 5)
        engine.ingest(event(.waitingInput, agent: "claude-code", session: "b", at: clock.now))
        clock.advance(by: 5)
        #expect(engine.currentFocus()?.agentID == "codex")
    }

    @Test("selection does not depend on dictionary iteration order")
    func deterministic() {
        // Identical timestamps, so the only thing that could break the tie is
        // iteration order — which must never leak into the result.
        func run(_ order: [String]) -> String? {
            let (engine, _) = makeEngine()
            for agent in order {
                engine.ingest(event(.waitingInput, agent: agent, session: "s", at: start))
            }
            return engine.currentFocus()?.agentID
        }
        #expect(run(["beta", "alpha"]) == run(["alpha", "beta"]))
        #expect(run(["a", "b", "c", "d"]) == run(["d", "c", "b", "a"]))
    }

    @Test("seniority breaks ties when two sessions started at different times")
    func seniorityWins() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.waitingInput, agent: "first", session: "a"))
        clock.advance(by: 5)
        engine.ingest(event(.waitingInput, agent: "second", session: "b", at: clock.now))
        #expect(engine.currentFocus()?.agentID == "first")
    }
}

@Suite("ActivityEngine — aging")
struct AgingTests {

    @Test("aging does not apply to a working session — it is progressing, not waiting")
    func runningDoesNotAge() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working, agent: "codex", session: "a"))
        clock.advance(by: 1000)
        let activity = engine.allActivities()[0]
        #expect(engine.effectiveClass(activity, now: clock.now) == .active)
    }

    @Test("a failed session is promoted to the attention class once it has waited long enough")
    func failureAgesUp() {
        let (engine, _) = makeEngine()
        engine.ingest(event(.failed, agent: "codex", session: "a"))
        let activity = engine.allActivities()[0]

        #expect(engine.effectiveClass(activity, now: start) == .failure)
        #expect(engine.effectiveClass(activity, now: start.addingTimeInterval(89)) == .failure)
        #expect(engine.effectiveClass(activity, now: start.addingTimeInterval(90)) == .attention)
    }

    @Test("promotion never overshoots the attention class")
    func agingIsCapped() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.failed, agent: "codex", session: "a"))
        let activity = engine.allActivities()[0]
        clock.advance(by: 100_000)
        #expect(engine.effectiveClass(activity, now: clock.now) == .attention)
    }

    @Test("completed ages up by at most maxPromotions classes")
    func completedCappedAtMaxPromotions() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.completed, agent: "codex", session: "a"))
        let activity = engine.allActivities()[0]
        // settled(3) with 2 promotions -> failure(1)
        clock.advance(by: 1000)
        #expect(engine.effectiveClass(activity, now: clock.now) == .failure)
    }

    @Test("a stale failure eventually outranks a fresh working session")
    func agedFailureBeatsFreshWork() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.failed, agent: "codex", session: "old"))
        clock.advance(by: 200)   // promote the failure into the attention class
        engine.ingest(event(.working, agent: "claude-code", session: "new", at: clock.now))
        clock.advance(by: 10)
        #expect(engine.currentFocus()?.agentID == "codex")
    }
}

@Suite("ActivityEngine — focus hold and dwell")
struct FocusHoldTests {

    @Test("a blocking session cannot instantly steal focus from a working one")
    func focusHoldPreventsThrash() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working, agent: "codex", session: "a"))
        #expect(engine.currentFocus()?.agentID == "codex")

        clock.advance(by: 0.5)   // still inside focusHold, and past urgentOverride
        engine.ingest(event(.waitingInput, agent: "claude-code", session: "b", at: clock.now))
        #expect(engine.currentFocus()?.agentID == "codex", "working session should keep focus")
    }

    @Test("after focus hold expires the blocking session takes over")
    func takeoverAfterHold() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working, agent: "codex", session: "a"))
        _ = engine.currentFocus()
        clock.advance(by: 3.1)
        engine.ingest(event(.waitingInput, agent: "claude-code", session: "b", at: clock.now))
        #expect(engine.currentFocus()?.agentID == "claude-code")
    }

    @Test("a blocking session interrupts an idle one after the short override")
    func urgentOverrideOnIdle() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.sessionStarted, agent: "codex", session: "a"))  // idle
        _ = engine.currentFocus()

        clock.advance(by: 1.5)   // past urgentOverride, inside focusHold
        engine.ingest(event(.waitingApproval, agent: "claude-code", session: "b", at: clock.now))
        #expect(engine.currentFocus()?.agentID == "claude-code")
    }

    @Test("the completion dwell keeps a finished session on screen")
    func completionDwell() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working, agent: "codex", session: "a"))
        _ = engine.currentFocus()

        clock.advance(by: 5)
        engine.ingest(event(.completed, agent: "codex", session: "a", at: clock.now))
        #expect(engine.currentFocus()?.state == .completed)

        clock.advance(by: 1)
        engine.ingest(event(.waitingInput, agent: "claude-code", session: "b", at: clock.now))
        #expect(engine.currentFocus()?.agentID == "codex", "completion should not be clipped")

        clock.advance(by: 4)
        #expect(engine.currentFocus()?.agentID == "claude-code")
    }

    @Test("an identical repeated event never triggers a focus change")
    func noThrashOnRepeat() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working, agent: "codex", session: "a"))
        let first = engine.currentFocus()
        clock.advance(by: 0.01)
        engine.ingest(event(.working, agent: "codex", session: "a", at: clock.now))
        #expect(engine.currentFocus() == first)
    }
}

@Suite("ActivityEngine — stale expiry")
struct StaleExpiryTests {

    @Test("a silent running session degrades to unknown")
    func runningGoesUnknown() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working, agent: "codex", session: "a"))
        clock.advance(by: 31)
        #expect(engine.currentFocus()?.state == .unknown)
    }

    @Test("a silent session is left alone before its timeout")
    func notYetStale() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working, agent: "codex", session: "a"))
        clock.advance(by: 29)
        #expect(engine.currentFocus()?.state == .running)
    }

    @Test("a session waiting for the user never expires — they may be away for hours")
    func waitingNeverExpires() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.waitingInput, agent: "codex", session: "a"))
        clock.advance(by: 60 * 60 * 8)
        #expect(engine.currentFocus()?.state == .waitingInput)
    }

    @Test("an approval prompt expires after five minutes")
    func approvalExpires() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.waitingApproval, agent: "codex", session: "a"))
        clock.advance(by: 299)
        #expect(engine.currentFocus()?.state == .waitingApproval)
        clock.advance(by: 2)
        #expect(engine.currentFocus()?.state == .unknown)
    }

    @Test("unknown degrades to idle")
    func unknownGoesIdle() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working, agent: "codex", session: "a"))
        clock.advance(by: 31)
        #expect(engine.currentFocus()?.state == .unknown)
        clock.advance(by: 61)
        #expect(engine.currentFocus()?.state == .idle)
    }

    @Test("a stale failure eventually returns to idle")
    func failureGoesIdle() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.failed, agent: "codex", session: "a"))
        clock.advance(by: 601)
        #expect(engine.currentFocus()?.state == .idle)
    }

    @Test("a deadline begins at the last event, not the state change")
    func deadlineAnchorsOnLastEvent() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working, agent: "codex", session: "a"))
        for _ in 0..<5 {
            clock.advance(by: 20)
            engine.ingest(event(.working, agent: "codex", session: "a", at: clock.now))
        }
        #expect(engine.currentFocus()?.state == .running, "repeated activity keeps the session live")
        clock.advance(by: 31)
        #expect(engine.currentFocus()?.state == .unknown)
    }
}

@Suite("ActivityEngine — multiple agents in parallel")
struct ConcurrencyTests {

    @Test("many sessions are all tracked independently")
    func tracksAllSessions() {
        let (engine, clock) = makeEngine()
        let agents = ["codex", "claude-code", "grok", "pi"]
        for (i, agent) in agents.enumerated() {
            engine.ingest(event(.working, agent: agent, session: "s\(i)", at: clock.now))
            clock.advance(by: 1)
        }
        #expect(engine.allActivities().count == 4)
    }

    @Test("one session closing leaves the others alone")
    func closingOneDoesNotAffectOthers() {
        let (engine, clock) = makeEngine()
        engine.ingest(event(.working, agent: "codex", session: "a"))
        clock.advance(by: 1)
        engine.ingest(event(.working, agent: "pi", session: "b", at: clock.now))
        clock.advance(by: 1)
        engine.ingest(event(.sessionClosed, agent: "codex", session: "a", at: clock.now))

        #expect(engine.allActivities().count == 1)
        #expect(engine.allActivities()[0].agentID == "pi")
    }

    @Test("sessions are listed in arrival order, not dictionary order")
    func arrivalOrderStable() {
        let (engine, clock) = makeEngine()
        let agents = ["zeta", "alpha", "mu", "beta"]
        for (i, agent) in agents.enumerated() {
            engine.ingest(event(.working, agent: agent, session: "s\(i)", at: clock.now))
            clock.advance(by: 1)
        }
        #expect(engine.allActivities().map(\.agentID) == agents)
    }
}
