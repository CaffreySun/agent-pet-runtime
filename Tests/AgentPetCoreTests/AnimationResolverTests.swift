import CoreGraphics
import Foundation
import Testing
@testable import AgentPetCore

private let resolver = AnimationResolver()
private let v1 = CompatibilityProfile.openAICodexV1
private let v2 = CompatibilityProfile.openAICodexV2

private func track(_ name: String, _ profile: CompatibilityProfile = .openAICodexV1) -> AnimationTrack {
    profile.track(named: name)!
}

@Suite("Contract frame timings")
struct ContractTimingTests {

    /// Every value here is copied from the published animation-row table.
    /// The point of the table is that timings are *not* uniform, so a single
    /// frame rate cannot reproduce any of these rows.
    @Test("idle holds its ends and quickens its middle")
    func idleTimings() {
        let idle = track("idle")
        #expect(idle.frameDurations == [0.280, 0.110, 0.110, 0.140, 0.140, 0.320])
        // The first and last frames are held far longer than the middle ones.
        #expect(idle.frameDurations.first! > idle.frameDurations[1] * 2)
        #expect(idle.frameDurations.last! > idle.frameDurations[3] * 2)
        // And the cycle is a breath — about a second, like the other rows'
        // passes, not the six-second settle Codex only shows after a state.
        #expect(abs(idle.duration - 1.10) < 0.0001)
    }

    @Test("row durations match the published table")
    func rowDurations() {
        let expected: [(name: String, frames: Int, total: TimeInterval)] = [
            ("running-right", 8, 7 * 0.120 + 0.220),
            ("running-left",  8, 7 * 0.120 + 0.220),
            ("waving",        4, 3 * 0.140 + 0.280),
            ("jumping",       5, 4 * 0.140 + 0.280),
            ("failed",        8, 7 * 0.140 + 0.240),
            ("waiting",       6, 5 * 0.150 + 0.260),
            ("running",       6, 5 * 0.120 + 0.220),
            ("review",        6, 5 * 0.150 + 0.280),
        ]
        for entry in expected {
            let track = track(entry.name)
            #expect(track.frameCount == entry.frames, "\(entry.name) frame count")
            #expect(abs(track.duration - entry.total) < 0.0001,
                    "\(entry.name) duration was \(track.duration), expected \(entry.total)")
        }
    }

    @Test("every standard row holds its final frame longer than a middle one")
    func finalFrameHeld() {
        for name in ["running-right", "running-left", "waving", "jumping",
                     "failed", "waiting", "running", "review"] {
            let track = track(name)
            #expect(track.frameDurations.last! > track.frameDurations[0],
                    "\(name) does not hold its final frame")
        }
    }

    @Test("a uniform frame rate could not express idle")
    func uniformFPSWouldBeWrong() {
        let idle = track("idle")
        // At an average rate every frame would be ~183ms; the real track spans
        // 110ms to 320ms, so the pet would breathe visibly wrong.
        let average = idle.duration / Double(idle.frameCount)
        #expect(idle.frameDurations.min()! < average * 0.7)
        #expect(idle.frameDurations.max()! > average * 1.6)
    }
}

@Suite("Frame advance")
struct FrameAdvanceTests {

    @Test("a frame is held for its own duration, not a shared one")
    func perFrameDurations() {
        let idle = track("idle")   // 280, 110, 110, 140, 140, 320
        #expect(idle.frameIndex(at: 0).index == 0)
        #expect(idle.frameIndex(at: 0.279).index == 0)
        #expect(idle.frameIndex(at: 0.280).index == 1)
        #expect(idle.frameIndex(at: 0.389).index == 1)
        #expect(idle.frameIndex(at: 0.390).index == 2)
        #expect(idle.frameIndex(at: 0.500).index == 3)
    }

    @Test("the final frame is held for its own longer duration")
    func finalFrameHold() {
        let idle = track("idle")
        let beforeLast = idle.duration - idle.frameDurations.last!
        #expect(idle.frameIndex(at: beforeLast).index == 5)
        #expect(idle.frameIndex(at: idle.duration - 0.001).index == 5)
    }

    @Test("a looping track wraps")
    func loopingWraps() {
        let idle = track("idle")
        #expect(idle.frameIndex(at: idle.duration).index == 0)
        #expect(idle.frameIndex(at: idle.duration * 50).index == 0)
        #expect(!idle.frameIndex(at: idle.duration * 50).finished)
    }

    @Test("a one-shot holds its last frame and reports finished")
    func oneShotHolds() {
        let waving = track("waving")
        #expect(!waving.frameIndex(at: waving.duration - 0.001).finished)

        let done = waving.frameIndex(at: waving.duration)
        #expect(done.index == waving.frameCount - 1)
        #expect(done.finished)

        let muchLater = waving.frameIndex(at: 100)
        #expect(muchLater.index == waving.frameCount - 1, "a finished one-shot must not wrap")
        #expect(muchLater.finished)
    }

    @Test("a static pose never advances, however long it is held")
    func staticPose() {
        let look = track("look-a", v2)
        #expect(look.loop == .staticPose)
        for elapsed in [0.0, 1.0, 1000.0] {
            #expect(look.frameIndex(at: elapsed).index == 0)
            #expect(!look.frameIndex(at: elapsed).finished)
        }
    }

    @Test("negative elapsed is treated as the first frame")
    func negativeElapsed() {
        #expect(track("idle").frameIndex(at: -5).index == 0)
    }
}

@Suite("Look directions")
struct LookDirectionTests {

    @Test("straight up is the first pose, not a neutral front view")
    func upIsFirst() {
        // The contract is explicit: 000 means up / 12 o'clock, and forward is
        // the no-vector deadzone rather than a pose.
        #expect(LookDirection.cell(forAngle: 0) == (9, 0))
    }

    @Test("the sixteen poses run clockwise from up")
    func sixteenPoses() {
        // Written as a table rather than sixteen parameterised cases: the
        // type checker gives up on an argument list that wide.
        let expected: [(angle: Double, row: Int, column: Int)] = [
            (0, 9, 0), (22.5, 9, 1), (45, 9, 2), (67.5, 9, 3),
            (90, 9, 4), (112.5, 9, 5), (135, 9, 6), (157.5, 9, 7),
            (180, 10, 0), (202.5, 10, 1), (225, 10, 2), (247.5, 10, 3),
            (270, 10, 4), (292.5, 10, 5), (315, 10, 6), (337.5, 10, 7),
        ]
        for entry in expected {
            let cell = LookDirection.cell(forAngle: entry.angle)
            #expect(cell == (entry.row, entry.column),
                    "\(entry.angle)° gave \(cell), expected (\(entry.row), \(entry.column))")
        }

        // And the whole circle is covered exactly once.
        let sectors = Set((0..<16).map { LookDirection.cell(forAngle: Double($0) * 22.5).row * 8
            + LookDirection.cell(forAngle: Double($0) * 22.5).column })
        #expect(sectors.count == 16)
    }

    @Test("right is 90 degrees, which is the positive x axis")
    func rightIsNinety() {
        let angle = LookDirection.angle(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0))
        #expect(abs(angle - 90) < 0.001)
        #expect(LookDirection.cell(forAngle: angle) == (9, 4))
    }

    @Test("up is 0 degrees even though screen y grows downward")
    func upIsZero() {
        let angle = LookDirection.angle(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: -100))
        #expect(abs(angle) < 0.001)
    }

    @Test("down is 180 degrees and lives in the second look row")
    func downIsOneEighty() {
        let angle = LookDirection.angle(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 0, y: 100))
        #expect(abs(angle - 180) < 0.001)
        #expect(LookDirection.cell(forAngle: angle) == (10, 0))
    }

    @Test("angles wrap rather than going out of range", arguments: [
        -22.5, 360.0, 720.0, -360.0, 382.5,
    ])
    func wrapping(angle: Double) {
        let cell = LookDirection.cell(forAngle: angle)
        #expect(cell.row == 9 || cell.row == 10)
        #expect(cell.column >= 0 && cell.column < 8)
    }

    @Test("a pose is centred in its sector, so slight jitter does not flicker")
    func sectorCentring() {
        // Pointing a hair either side of 45 degrees must not jump two poses.
        #expect(LookDirection.cell(forAngle: 40) == LookDirection.cell(forAngle: 45))
        #expect(LookDirection.cell(forAngle: 50) == LookDirection.cell(forAngle: 45))
    }

    @Test("V1 has no gaze rows and V2 does")
    func profileSupport() {
        #expect(!v1.hasLookDirections)
        #expect(v1.lookRows.isEmpty)
        #expect(v2.hasLookDirections)
        #expect(v2.lookRows == [9, 10])
        #expect(v2.track(atRow: 9)?.kind == .look)
        #expect(v2.track(atRow: 10)?.kind == .look)
    }
}

@Suite("Presentation layering")
struct PresentationLayerTests {

    private func situation(
        state: AgentState = .idle,
        stateElapsed: TimeInterval = 0,
        drag: PetSituation.Drag? = nil,
        gesture: PetSituation.Gesture? = nil,
        hover: PetSituation.Hover? = nil,
        look: Double? = nil,
        reducedMotion: Bool = false
    ) -> PetSituation {
        PetSituation(
            agentState: state, agentStateElapsed: stateElapsed,
            drag: drag, gesture: gesture, hover: hover, lookAngle: look,
            reducedMotion: reducedMotion
        )
    }

    @Test("the pointer on the pet plays the jump, and the landing pose is held")
    func hoverPlaysTheJumpAndHolds() {
        // Codex's mascot is `state: hovered ? "jumping" : state`, and its
        // sprite timer stops on the last frame of a one-shot. Ported as it is:
        // one jump per arrival, then the pose it landed in — not a loop, and
        // not a fall-through to idle.
        let jumping = track("jumping")
        let first = resolver.resolve(situation(hover: .init(elapsed: 0)), profile: v1)
        #expect(first?.trackName == "jumping")
        #expect(first?.row == 4)
        #expect(first?.column == 0)

        let held = resolver.resolve(
            situation(hover: .init(elapsed: jumping.duration + 10)), profile: v1
        )
        #expect(held?.column == jumping.frameCount - 1, "the last frame stays put")
        #expect(held?.isFinished == true)
    }

    @Test("hovering outranks the agent state, and gives it back on the way out")
    func hoverOverridesState() {
        let hovered = resolver.resolve(
            situation(state: .running, hover: .init(elapsed: 0.1)), profile: v1
        )
        #expect(hovered?.trackName == "jumping", "the pet notices the pointer mid-work")

        let left = resolver.resolve(situation(state: .running), profile: v1)
        #expect(left?.trackName == "running", "the pointer leaving hands the row back")
    }

    @Test("a drag outranks a hover, and a gesture plays over it")
    func hoverYieldsToHands() {
        let dragged = resolver.resolve(
            situation(
                drag: .init(direction: .right, elapsed: 0.05),
                hover: .init(elapsed: 5)
            ),
            profile: v1
        )
        #expect(dragged?.trackName == "running-right")

        let clicked = resolver.resolve(
            situation(gesture: .init(trackName: "waving", elapsed: 0.05), hover: .init(elapsed: 5)),
            profile: v1
        )
        #expect(clicked?.trackName == "waving")
    }

    @Test("with nothing happening the pet is idle")
    func idleByDefault() {
        let frame = resolver.resolve(situation(), profile: v1)
        #expect(frame?.trackName == "idle")
        #expect(frame?.row == 0)
    }

    @Test("an agent state selects its own row")
    func stateSelectsRow() {
        #expect(resolver.resolve(situation(state: .running), profile: v1)?.row == 7)
        #expect(resolver.resolve(situation(state: .waitingInput), profile: v1)?.row == 6)
        #expect(resolver.resolve(situation(state: .failed), profile: v1)?.row == 5)
        #expect(resolver.resolve(situation(state: .completed), profile: v1)?.row == 8)
    }

    @Test("dragging picks the locomotion row for the direction")
    func dragLocomotion() {
        let right = resolver.resolve(
            situation(drag: .init(direction: .right, elapsed: 0.1)), profile: v1
        )
        #expect(right?.trackName == "running-right")
        #expect(right?.row == 1)

        let left = resolver.resolve(
            situation(drag: .init(direction: .left, elapsed: 0.1)), profile: v1
        )
        #expect(left?.trackName == "running-left")
        #expect(left?.row == 2)
    }

    @Test("dragging outranks everything, because the user has the pet in hand")
    func dragOutranksAll() {
        let frame = resolver.resolve(
            situation(
                state: .waitingInput,
                drag: .init(direction: .right, elapsed: 0.05),
                gesture: .init(trackName: "jumping", elapsed: 0.05),
                look: 90
            ),
            profile: v2
        )
        #expect(frame?.trackName == "running-right")
    }

    @Test("dragging overrides a blocking agent state")
    func dragOverridesWaiting() {
        // The agent may be waiting, but the user is physically moving the pet.
        let frame = resolver.resolve(
            situation(state: .waitingInput, drag: .init(direction: .left, elapsed: 0.05)),
            profile: v1
        )
        #expect(frame?.trackName == "running-left")
    }

    @Test("a gesture plays over the agent state until it finishes")
    func gestureOverridesState() {
        let waving = track("waving")
        let during = resolver.resolve(
            situation(state: .running, gesture: .init(trackName: "waving", elapsed: 0.1)),
            profile: v1
        )
        #expect(during?.trackName == "waving")

        let after = resolver.resolve(
            situation(state: .running, gesture: .init(trackName: "waving", elapsed: waving.duration + 1)),
            profile: v1
        )
        #expect(after?.trackName == "running", "a finished gesture must yield to the state")
    }

    @Test("gaze is used only when the pet would otherwise be idle")
    func gazeOnlyWhenIdle() {
        let gazing = resolver.resolve(situation(look: 90), profile: v2)
        #expect(gazing?.row == 9)
        #expect(gazing?.column == 4)

        // A working agent is more important than where the pointer is.
        let working = resolver.resolve(situation(state: .running, look: 90), profile: v2)
        #expect(working?.trackName == "running")
    }

    @Test("a V1 pet ignores gaze, having nowhere to put it")
    func v1IgnoresGaze() {
        let frame = resolver.resolve(situation(look: 90), profile: v1)
        #expect(frame?.trackName == "idle")
    }

    @Test("with no gaze angle the pet falls back to idle")
    func deadzoneFallsBack() {
        // This is the contract's "no-vector deadzone".
        let frame = resolver.resolve(situation(look: nil), profile: v2)
        #expect(frame?.trackName == "idle")
    }

    @Test("completion inspects the finished work, then settles to idle")
    func completionSettles() {
        let review = track("review")

        let during = resolver.resolve(
            situation(state: .completed, stateElapsed: 0.1), profile: v1
        )
        #expect(during?.trackName == "review", "a finished turn is inspected, not celebrated")

        let after = resolver.resolve(
            situation(state: .completed, stateElapsed: review.duration * 3 + 0.5), profile: v1
        )
        #expect(after?.trackName == "idle", "the pet must not inspect forever")
    }

    @Test("failure plays through and then settles rather than looping a grimace")
    func failureSettles() {
        let failed = track("failed")
        let during = resolver.resolve(situation(state: .failed, stateElapsed: 0.2), profile: v1)
        #expect(during?.trackName == "failed")

        let after = resolver.resolve(
            situation(state: .failed, stateElapsed: failed.duration * 3 + 0.5), profile: v1
        )
        #expect(after?.trackName == "idle")
    }

    @Test("conditions loop for as long as they last, however long that is")
    func conditionsLoop() {
        // Working and waiting are conditions, not moments: an agent can think
        // for ten minutes and an approval can sit for an hour. The pet keeps
        // animating its row the whole time — settling into a calm breath
        // three seconds in reads as "asleep already" while the agent is
        // plainly still working.
        for state in [AgentState.running, .waitingInput, .waitingApproval] {
            for elapsed in [0.5, 5.0, 60.0, 3600.0] {
                let frame = resolver.resolve(
                    situation(state: state, stateElapsed: elapsed), profile: v1
                )
                #expect(frame?.trackName == state.animationTrackName,
                        "\(state) stopped animating after \(elapsed)s")
                #expect(frame?.isFinished == false)
            }
            let track = track(state.animationTrackName)
            #expect(track.repeats == 1, "\(state) should loop rather than settle")
        }
    }

    @Test("moments play three passes and then settle into the breath")
    func momentsSettle() {
        // A finished turn and a failure are news, not conditions: the row
        // plays three times — Codex's `[...row, ...row, ...row, ...idle]` —
        // and then the pet breathes, which is what stops it holding a pose.
        for state in [AgentState.completed, .failed] {
            let track = track(state.animationTrackName)
            #expect(track.repeats == 3, "\(state) should repeat its row three times")

            let firstPass = resolver.resolve(
                situation(state: state, stateElapsed: track.duration * 0.5), profile: v1
            )
            #expect(firstPass?.trackName == state.animationTrackName)

            let settling = resolver.resolve(
                situation(state: state, stateElapsed: track.duration * 3 + 0.5), profile: v1
            )
            #expect(settling?.trackName == "idle", "\(state) should settle into idle")
            #expect(settling?.isFinished == false, "and keep breathing quietly")
        }
    }

    @Test("a working pet does not hand over to gaze")
    func workingIgnoresGaze() {
        // The agent is still working, so the pet must not turn away to watch
        // the pointer — at any point in the state's life.
        for elapsed in [0.5, 60.0] {
            let frame = resolver.resolve(
                situation(state: .running, stateElapsed: elapsed, look: 90), profile: v2
            )
            #expect(frame?.trackName == "running", "gaze would have shown a look row")
        }
    }

    @Test("reduced motion holds the first frame of whatever would have played")
    func reducedMotionHoldsStill() {
        // Codex's reduced-motion path is one frame per state; so is this, and
        // the setting reaches every layer, not just idle.
        for state in AgentState.allCases {
            let frame = resolver.resolve(
                situation(state: state, stateElapsed: 3.0, reducedMotion: true), profile: v1
            )
            #expect(frame?.column == 0, "\(state) should not advance under reduced motion")
        }

        let dragged = resolver.resolve(
            situation(drag: .init(direction: .right, elapsed: 0.9), reducedMotion: true),
            profile: v1
        )
        #expect(dragged?.trackName == "running-right")
        #expect(dragged?.column == 0, "a dragged pet holds still too")

        let gazing = resolver.resolve(
            situation(look: 90, reducedMotion: true), profile: v2
        )
        #expect(gazing?.column == 0, "the gaze pose does not wander")
    }

    @Test("every state resolves to a playable frame in both profiles")
    func everyStatePlayable() {
        for profile in CompatibilityProfile.allCases {
            for state in AgentState.allCases {
                let frame = resolver.resolve(situation(state: state), profile: profile)
                let track = profile.track(named: state.animationTrackName)!
                #expect(frame != nil, "\(state) unresolvable in \(profile.rawValue)")
                #expect(frame!.column < track.frameCount)
            }
        }
    }
}

@Suite("Drag direction")
struct DragDirectionTests {

    @Test("horizontal movement picks its direction")
    func horizontal() {
        #expect(HorizontalDirection.from(dx: 10, dy: 0, previous: nil) == .right)
        #expect(HorizontalDirection.from(dx: -10, dy: 0, previous: nil) == .left)
    }

    @Test("a mostly vertical drag keeps the direction it had")
    func verticalKeepsPrevious() {
        // The atlas has no row for travelling straight up, and flipping the
        // pet as the cursor wobbles would look like a glitch.
        #expect(HorizontalDirection.from(dx: 1, dy: 50, previous: .left) == .left)
        #expect(HorizontalDirection.from(dx: -1, dy: 50, previous: .right) == .right)
    }

    @Test("no movement keeps the previous direction")
    func noMovement() {
        #expect(HorizontalDirection.from(dx: 0, dy: 0, previous: .left) == .left)
        #expect(HorizontalDirection.from(dx: 0, dy: 0, previous: nil) == nil)
    }

    @Test("direction maps to the right atlas row")
    func trackNames() {
        #expect(HorizontalDirection.left.trackName == "running-left")
        #expect(HorizontalDirection.right.trackName == "running-right")
        #expect(track("running-left", v2).row == 2)
        #expect(track("running-right", v2).row == 1)
    }

    @Test("locomotion rows exist in both profiles")
    func bothProfiles() {
        for profile in CompatibilityProfile.allCases {
            #expect(profile.track(named: "running-left") != nil)
            #expect(profile.track(named: "running-right") != nil)
        }
    }
}

@Suite("State to track mapping")
struct StateTrackMappingTests {

    @Test("each state maps to the documented row", arguments: [
        (AgentState.idle, "idle", 0),
        (.running, "running", 7),
        (.waitingInput, "waiting", 6),
        (.waitingApproval, "waiting", 6),
        (.completed, "review", 8),
        (.failed, "failed", 5),
        (.paused, "idle", 0),
        (.unknown, "idle", 0),
    ])
    func mapping(state: AgentState, name: String, row: Int) {
        #expect(state.animationTrackName == name)
        #expect(v1.track(named: name)?.row == row)
    }

    @Test("no agent state selects a locomotion or gaze row")
    func nonStateRowsAreNotSelected() {
        for state in AgentState.allCases {
            let track = v1.track(named: state.animationTrackName)
            #expect(track?.kind == .state || track?.kind == .gesture,
                    "\(state) selected a \(track?.kind.rawValue ?? "?") row")
        }
    }

    @Test("waving is a reaction to the user, not to the agent")
    func wavingIsNotAState() {
        // `waving` is "a greeting or attention gesture" — nothing the agent
        // does selects it; clicking the pet does.
        for state in AgentState.allCases {
            #expect(state.animationTrackName != "waving")
        }
    }
}
