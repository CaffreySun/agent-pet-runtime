import Foundation

/// Which frame of which track should be on screen right now.
public struct AnimationFrame: Sendable, Equatable {
    public let trackName: String
    public let row: Int
    public let column: Int
    /// True once a `.once` track has played past its last frame.
    public let isFinished: Bool

    public init(trackName: String, row: Int, column: Int, isFinished: Bool) {
        self.trackName = trackName
        self.row = row
        self.column = column
        self.isFinished = isFinished
    }
}

/// The pet's on-screen state: which track is playing and how far into it we
/// are.
///
/// Pure arithmetic over a track and an elapsed time — no timers, no display
/// link, no AppKit. The renderer supplies `elapsed`; tests supply whatever
/// they like.
public struct AnimationResolver: Sendable {

    public init() {}

    /// Frame to show `elapsed` seconds into `track`.
    ///
    /// A `.loop` track wraps. A `.once` track holds its final frame and
    /// reports `isFinished`, which is the renderer's cue to fall back to the
    /// session's state track.
    public func frame(for track: AnimationTrack, elapsed: TimeInterval) -> AnimationFrame {
        guard track.frameCount > 0 else {
            return AnimationFrame(trackName: track.name, row: track.row, column: 0, isFinished: true)
        }

        // Negative elapsed happens the instant a track is switched in, before
        // the first clock tick. Treat it as frame 0 rather than crashing.
        let safeElapsed = max(0, elapsed)
        let rawFrame = Int(safeElapsed * track.fps)

        switch track.loop {
        case .loop:
            let column = rawFrame % track.frameCount
            return AnimationFrame(trackName: track.name, row: track.row,
                                  column: column, isFinished: false)

        case .once:
            let finished = safeElapsed >= track.duration
            let column = min(rawFrame, track.frameCount - 1)
            return AnimationFrame(trackName: track.name, row: track.row,
                                  column: column, isFinished: finished)
        }
    }

    /// Resolves what to show, preferring an unfinished gesture over the
    /// session's steady state.
    ///
    /// A `waving` gesture triggered by completion plays through once and then
    /// hands control back to whatever the state track is — which, for a
    /// completed session, is `waving` again. Without the hand-back the pet
    /// would wave forever.
    public func resolve(
        state: AgentState,
        profile: CompatibilityProfile,
        stateElapsed: TimeInterval,
        gesture: (track: AnimationTrack, elapsed: TimeInterval)?
    ) -> AnimationFrame? {
        if let gesture {
            let frame = self.frame(for: gesture.track, elapsed: gesture.elapsed)
            if !frame.isFinished { return frame }
        }

        guard let track = profile.track(named: state.animationTrackName) else { return nil }
        return frame(for: track, elapsed: stateElapsed)
    }

    /// Where a gesture should hand back to. `completed` is the one state whose
    /// steady track is itself a one-shot gesture, so it settles into `idle`
    /// once the wave is over.
    public func settledState(after gesture: AnimationTrack, from state: AgentState) -> AgentState {
        if state == .completed && gesture.name == AgentState.completed.animationTrackName {
            return .idle
        }
        return state
    }
}
