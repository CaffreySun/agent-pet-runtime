import Foundation
import Testing
@testable import AgentPetCore

private let resolver = AnimationResolver()
private let v1 = CompatibilityProfile.openAICodexV1

private func track(_ name: String) -> AnimationTrack {
    v1.track(named: name)!
}

@Suite("Frame timing")
struct FrameTimingTests {

    @Test("elapsed zero shows the first frame")
    func firstFrame() {
        let frame = resolver.frame(for: track("idle"), elapsed: 0)
        #expect(frame.column == 0)
        #expect(frame.row == 0)
        #expect(!frame.isFinished)
    }

    @Test("the frame advances at the track's fps")
    func advancesAtFPS() {
        let idle = track("idle")   // 6 frames at 8 fps -> 125ms each
        #expect(resolver.frame(for: idle, elapsed: 0.124).column == 0)
        #expect(resolver.frame(for: idle, elapsed: 0.125).column == 1)
        #expect(resolver.frame(for: idle, elapsed: 0.250).column == 2)
    }

    @Test("a looping track wraps at its frame count")
    func loopingWraps() {
        let idle = track("idle")   // 6 frames
        #expect(resolver.frame(for: idle, elapsed: idle.duration).column == 0)
        #expect(resolver.frame(for: idle, elapsed: idle.duration + 0.125).column == 1)
        #expect(resolver.frame(for: idle, elapsed: idle.duration * 100).column == 0)
    }

    @Test("a one-shot track holds its last frame and reports finished")
    func oneShotHolds() {
        let waving = track("waving")   // 4 frames at 8 fps -> 0.5s
        #expect(resolver.frame(for: waving, elapsed: 0.49).column == 3)
        #expect(!resolver.frame(for: waving, elapsed: 0.49).isFinished)

        let done = resolver.frame(for: waving, elapsed: 0.5)
        #expect(done.column == 3)
        #expect(done.isFinished)

        let later = resolver.frame(for: waving, elapsed: 10)
        #expect(later.column == 3, "a finished one-shot must not wrap back to frame 0")
        #expect(later.isFinished)
    }

    @Test("negative elapsed is treated as the first frame")
    func negativeElapsed() {
        let frame = resolver.frame(for: track("running"), elapsed: -1)
        #expect(frame.column == 0)
    }

    @Test("a track with no frames resolves to a finished first cell")
    func emptyTrack() {
        let reserved = CompatibilityProfile.openAICodexV2.track(named: "reserved-9")!
        let frame = resolver.frame(for: reserved, elapsed: 5)
        #expect(frame.column == 0)
        #expect(frame.isFinished)
    }

    @Test("the frame never leaves the row's usable columns")
    func staysInBounds() {
        for track in v1.tracks {
            for step in stride(from: 0.0, through: 5.0, by: 0.037) {
                let frame = resolver.frame(for: track, elapsed: step)
                #expect(frame.column >= 0)
                #expect(frame.column < track.frameCount,
                        "\(track.name) produced column \(frame.column) at t=\(step)")
            }
        }
    }

    @Test("the reported row matches the track's row")
    func rowMatchesTrack() {
        for track in v1.tracks {
            #expect(resolver.frame(for: track, elapsed: 0.3).row == track.row)
            #expect(resolver.frame(for: track, elapsed: 0.3).trackName == track.name)
        }
    }
}

@Suite("Presentation resolution")
struct PresentationResolutionTests {

    @Test("a plain state resolves to that state's track")
    func stateOnly() {
        let frame = resolver.resolve(state: .running, profile: v1, stateElapsed: 0.3, gesture: nil)
        #expect(frame?.trackName == "running")
        #expect(frame?.row == 7)
    }

    @Test("an unfinished gesture takes precedence over the state track")
    func gestureWins() {
        let frame = resolver.resolve(
            state: .idle, profile: v1, stateElapsed: 0,
            gesture: (track("jumping"), 0.0)
        )
        #expect(frame?.trackName == "jumping")
    }

    @Test("a finished gesture yields back to the state track")
    func gestureYieldsBack() {
        let waving = track("waving")
        let frame = resolver.resolve(
            state: .running, profile: v1, stateElapsed: 0.5,
            gesture: (waving, waving.duration + 1)
        )
        #expect(frame?.trackName == "running", "a finished gesture must not stick")
    }

    @Test("a completed session settles to idle once its wave is over")
    func completedSettles() {
        let waving = track("waving")
        let settled = resolver.settledState(after: waving, from: .completed)
        #expect(settled == .idle)
        #expect(resolver.resolve(state: settled, profile: v1, stateElapsed: 0, gesture: nil)?.trackName == "idle")
    }

    @Test("other states keep their own track after a gesture")
    func othersUnchanged() {
        let jumping = track("jumping")
        #expect(resolver.settledState(after: jumping, from: .running) == .running)
        #expect(resolver.settledState(after: jumping, from: .failed) == .failed)
    }

    @Test("every agent state resolves to a playable frame in both profiles")
    func everyStatePlayable() {
        for profile in CompatibilityProfile.allCases {
            for state in AgentState.allCases {
                let frame = resolver.resolve(state: state, profile: profile, stateElapsed: 0.2, gesture: nil)
                #expect(frame != nil, "\(state) unresolvable in \(profile.rawValue)")
                let track = profile.track(named: state.animationTrackName)!
                #expect(frame!.column < track.frameCount)
            }
        }
    }
}
