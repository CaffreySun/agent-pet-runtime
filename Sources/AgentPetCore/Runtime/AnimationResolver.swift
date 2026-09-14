import CoreGraphics
import Foundation

/// Which atlas cell should be on screen right now.
public struct AnimationFrame: Sendable, Equatable {
    public let trackName: String
    public let row: Int
    public let column: Int
    /// True once a one-shot track has played past its last frame.
    public let isFinished: Bool

    public init(trackName: String, row: Int, column: Int, isFinished: Bool) {
        self.trackName = trackName
        self.row = row
        self.column = column
        self.isFinished = isFinished
    }
}

public enum HorizontalDirection: String, Sendable, Equatable, CaseIterable {
    case left
    case right

    /// The atlas has one locomotion row per direction.
    public var trackName: String {
        switch self {
        case .left:  return "running-left"
        case .right: return "running-right"
        }
    }

    /// Which way a drag is heading.
    ///
    /// Vertical movement has no row of its own, so it must not flip the pet;
    /// a mostly-vertical drag keeps whatever direction it already had, and a
    /// drag that has never been horizontal defaults to right.
    public static func from(dx: CGFloat, dy: CGFloat, previous: HorizontalDirection?) -> HorizontalDirection? {
        guard abs(dx) >= 1 else { return previous }
        if abs(dy) > abs(dx) * 2 { return previous }
        return dx >= 0 ? .right : .left
    }
}

/// Everything the pet could be reacting to at one instant.
///
/// Made explicit rather than read from ambient state so the decision stays a
/// pure function of its inputs and can be tested without a window or a clock.
public struct PetSituation: Sendable, Equatable {

    public struct Drag: Sendable, Equatable {
        public let direction: HorizontalDirection
        public let elapsed: TimeInterval

        public init(direction: HorizontalDirection, elapsed: TimeInterval) {
            self.direction = direction
            self.elapsed = elapsed
        }
    }

    public struct Gesture: Sendable, Equatable {
        public let trackName: String
        public let elapsed: TimeInterval

        public init(trackName: String, elapsed: TimeInterval) {
            self.trackName = trackName
            self.elapsed = elapsed
        }
    }

    /// The pointer is over the pet. `elapsed` runs from the moment it arrived,
    /// because the row Codex plays for this is a one-shot that holds its last
    /// frame rather than a loop.
    public struct Hover: Sendable, Equatable {
        public let elapsed: TimeInterval

        public init(elapsed: TimeInterval) {
            self.elapsed = elapsed
        }
    }

    public var agentState: AgentState
    public var agentStateElapsed: TimeInterval
    /// Non-nil while the user is moving the pet.
    public var drag: Drag?
    /// Non-nil while a one-shot gesture is playing.
    public var gesture: Gesture?
    /// Non-nil while the pointer is over the pet.
    public var hover: Hover?
    /// Degrees clockwise from up, or nil when the pointer is in the deadzone.
    public var lookAngle: Double?
    /// The system asks for reduced motion, and the user has not opted out.
    /// Codex holds the first frame of whatever would be playing; so does this.
    public var reducedMotion: Bool

    public init(
        agentState: AgentState = .idle,
        agentStateElapsed: TimeInterval = 0,
        drag: Drag? = nil,
        gesture: Gesture? = nil,
        hover: Hover? = nil,
        lookAngle: Double? = nil,
        reducedMotion: Bool = false
    ) {
        self.agentState = agentState
        self.agentStateElapsed = agentStateElapsed
        self.drag = drag
        self.gesture = gesture
        self.hover = hover
        self.lookAngle = lookAngle
        self.reducedMotion = reducedMotion
    }
}

/// Chooses the frame to display. The whole visual behaviour of the pet lives
/// here.
public struct AnimationResolver: Sendable {

    public init() {}

    /// Frame to show `elapsed` seconds into `track`.
    public func frame(for track: AnimationTrack, elapsed: TimeInterval) -> AnimationFrame {
        let (index, finished) = track.frameIndex(at: elapsed)
        return AnimationFrame(
            trackName: track.name, row: track.row, column: index, isFinished: finished
        )
    }

    /// What the pet should be showing.
    ///
    /// Layers, most immediate first:
    ///
    /// 1. **Dragging** — the user has the pet in hand. Nothing outranks direct
    ///    manipulation, and the contract gives locomotion its own rows
    ///    precisely so the pet can walk as it is carried.
    /// 2. **A playing gesture** — a one-shot reaction, until it finishes.
    /// 3. **The pointer on the pet** — Codex plays its `jumping` row and holds
    ///    the landing pose until the pointer leaves.
    /// 4. **Agent state** — the row for what the agent is doing, played the
    ///    way Codex plays it: three passes, then the idle row, which is where
    ///    the loop restarts. The pet keeps breathing while the work continues;
    ///    the message beside it is what says the work is still happening.
    /// 5. **Gaze** — folded into the rows above rather than sitting under
    ///    them, because that is how Codex folds it: its sprite draws the look
    ///    frame *instead of* the animation, and only for the three rows whose
    ///    state it passes a look frame for (`idle`, `running`, `waving`). So a
    ///    working pet turns to watch the pointer just as an idle one does, and
    ///    a waiting one does not; with no direction vector everything falls
    ///    back to the row it would have played.
    /// 6. **Idle**.
    ///
    /// Under reduced motion every layer collapses to the first frame of
    /// whatever it would have played, which is what Codex does and what the
    /// system setting asks for.
    public func resolve(_ situation: PetSituation, profile: CompatibilityProfile) -> AnimationFrame? {
        guard let frame = resolveAnimating(situation, profile: profile) else { return nil }
        guard situation.reducedMotion else { return frame }
        return AnimationFrame(
            trackName: frame.trackName, row: frame.row, column: 0, isFinished: false
        )
    }

    /// Rows Codex shows the look frame *instead of*.
    ///
    /// Its mascot component passes `lookFrame` only when the animation it
    /// would play is one of these — `state: hovered ? "jumping" : state`, then
    /// `lookFrame: animates ? lookFrame : null` — and the sprite element draws
    /// the look frame rather than starting the row's timer. Every other row
    /// plays: `waiting`, `failed`, `review`, the jump, and locomotion.
    private static let gazeRows: Set<String> = ["idle", "running", "waving"]

    /// Plays a row as Codex plays it: a moment runs its passes and then hands
    /// over to the idle segment, which loops for as long as the occasion
    /// lasts.
    ///
    /// This is `Ulo`'s shape — `[...row, ...row, ...row, ...idle]` with
    /// `loopStartIndex` at the idle part — and it is what keeps a gesture or a
    /// hover from freezing on a last frame: the jump plays three times and the
    /// pet goes on breathing while the pointer stays.
    ///
    /// A condition (`repeats == 1`, e.g. `running`) skips straight to its own
    /// frame — this project keeps those looping their row, which is a
    /// deliberate deviation for states that outlive three passes by minutes.
    private func moment(
        _ track: AnimationTrack,
        elapsed: TimeInterval,
        _ profile: CompatibilityProfile
    ) -> AnimationFrame {
        let passes = track.duration * Double(track.repeats)
        if track.repeats > 1, elapsed >= passes, let idle = profile.track(named: "idle") {
            return frame(for: idle, elapsed: elapsed - passes)
        }
        return frame(for: track, elapsed: elapsed)
    }

    /// The look frame, when the pointer gives a direction and the row it would
    /// replace is one Codex replaces.
    private func gaze(
        overriding track: AnimationTrack,
        _ situation: PetSituation,
        _ profile: CompatibilityProfile
    ) -> AnimationFrame? {
        guard Self.gazeRows.contains(track.name),
              profile.hasLookDirections,
              let angle = situation.lookAngle
        else { return nil }

        let cell = LookDirection.cell(forAngle: angle)
        guard let look = profile.track(atRow: cell.row) else { return nil }
        return AnimationFrame(
            trackName: look.name, row: cell.row, column: cell.column, isFinished: false
        )
    }

    private func resolveAnimating(
        _ situation: PetSituation,
        profile: CompatibilityProfile
    ) -> AnimationFrame? {
        // 1. Dragging.
        if let drag = situation.drag,
           let track = profile.track(named: drag.direction.trackName) {
            return frame(for: track, elapsed: drag.elapsed)
        }

        // 2. A gesture in flight.
        if let gesture = situation.gesture,
           let track = profile.track(named: gesture.trackName) {
            let resolved = moment(track, elapsed: gesture.elapsed, profile)
            // A gesture that has played its passes falls through to the layers
            // beneath it — the state the agent is in is the better answer by
            // then, and on its own the gesture would sit in the idle segment
            // for as long as it was asked to.
            if gesture.elapsed < track.duration * Double(track.repeats) {
                // A wave is one of Codex's gaze rows — the greeting it plays
                // while the pet introduces itself is `waving` — so a pointer
                // with a direction still wins. A jump does not, which is the
                // difference between the two gestures.
                return gaze(overriding: track, situation, profile) ?? resolved
            }
        }

        // 3. The pointer on the pet.
        //
        // Codex's mascot is `state: hovered ? "jumping" : state`, and its
        // sprite timer stops on the last frame of a one-shot — so a cursor
        // resting on the pet sees one jump and then the landing pose, held for
        // as long as the cursor stays. That is the whole effect, and it is
        // ported rather than "improved": `frameIndex` clamps a one-shot at its
        // end, which is exactly the hold.
        if let hover = situation.hover,
           let jumping = profile.track(named: "jumping"),
           jumping.frameCount > 0 {
            return moment(jumping, elapsed: hover.elapsed, profile)
        }

        // 4. Agent state.
        //
        // Inactive states are skipped rather than drawn. `idle` is the
        // fallback, not something with a message of its own — returning it
        // here would end the decision before gaze ever got a chance, which is
        // why the pet would stare straight ahead no matter where the pointer
        // went.
        if situation.agentState.priorityClass != .inactive,
           let track = profile.track(named: situation.agentState.animationTrackName) {
            let elapsed = situation.agentStateElapsed
            let passes = track.duration * Double(track.repeats)

            // `running` is the row this layer shares with the gaze; a moment
            // that has settled into its idle tail is not (Codex's state is
            // still `review` or `failed` there, and those are not gaze rows).
            let settledIntoIdle = track.repeats > 1 && elapsed >= passes
            if !settledIntoIdle, let look = gaze(overriding: track, situation, profile) {
                return look
            }
            return moment(track, elapsed: elapsed, profile)
        }

        // 6. Idle — which is also where the gaze lives for a pet with nothing
        //    else to do, `idle` being one of the rows the look frame replaces.
        guard let idle = profile.track(named: "idle") else { return nil }
        return gaze(overriding: idle, situation, profile)
            ?? frame(for: idle, elapsed: situation.agentStateElapsed)
    }
}
