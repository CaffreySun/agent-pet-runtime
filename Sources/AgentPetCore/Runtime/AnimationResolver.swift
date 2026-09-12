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

    public var agentState: AgentState
    public var agentStateElapsed: TimeInterval
    /// Non-nil while the user is moving the pet.
    public var drag: Drag?
    /// Non-nil while a one-shot gesture is playing.
    public var gesture: Gesture?
    /// Degrees clockwise from up, or nil when the pointer is in the deadzone.
    public var lookAngle: Double?

    public init(
        agentState: AgentState = .idle,
        agentStateElapsed: TimeInterval = 0,
        drag: Drag? = nil,
        gesture: Gesture? = nil,
        lookAngle: Double? = nil
    ) {
        self.agentState = agentState
        self.agentStateElapsed = agentStateElapsed
        self.drag = drag
        self.gesture = gesture
        self.lookAngle = lookAngle
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
    /// 3. **Agent state** — what the agent is doing, when it is doing anything.
    /// 4. **Gaze** — when the pet would otherwise be idle and the pointer gives
    ///    it a direction to look in. The contract treats this as an
    ///    alternative to idle: with no direction vector it falls back.
    /// 5. **Idle**.
    public func resolve(_ situation: PetSituation, profile: CompatibilityProfile) -> AnimationFrame? {
        // 1. Dragging.
        if let drag = situation.drag,
           let track = profile.track(named: drag.direction.trackName) {
            return frame(for: track, elapsed: drag.elapsed)
        }

        // 2. A gesture in flight.
        if let gesture = situation.gesture,
           let track = profile.track(named: gesture.trackName) {
            let resolved = frame(for: track, elapsed: gesture.elapsed)
            // A finished gesture falls through to the layers beneath it rather
            // than sticking on its last frame.
            if !resolved.isFinished { return resolved }
        }

        // 3. Agent state.
        //
        // Inactive states are skipped rather than drawn. `idle` is the
        // fallback, not something with a message of its own — returning it
        // here would end the decision before gaze ever got a chance, which is
        // why the pet would stare straight ahead no matter where the pointer
        // went.
        if situation.agentState.priorityClass != .inactive,
           let track = profile.track(named: situation.agentState.animationTrackName) {
            let resolved = frame(for: track, elapsed: situation.agentStateElapsed)
            if !resolved.isFinished { return resolved }
            // A one-shot that has finished yields to the layers beneath it: a
            // finished task should not hold a frozen celebration, and a failed
            // one should not hold a frozen grimace.
            if !situation.agentState.animationPlaysOnce { return resolved }
        }

        // 4. Gaze.
        if let angle = situation.lookAngle, profile.hasLookDirections {
            let cell = LookDirection.cell(forAngle: angle)
            if let track = profile.track(atRow: cell.row) {
                return AnimationFrame(
                    trackName: track.name, row: cell.row, column: cell.column, isFinished: false
                )
            }
        }

        // 5. Idle.
        guard let idle = profile.track(named: "idle") else { return nil }
        return frame(for: idle, elapsed: situation.agentStateElapsed)
    }

    /// The state a session settles into once a one-shot has finished.
    ///
    /// `completed` is the one state whose reaction is itself the message — once
    /// the celebration is over there is nothing left to say, so the pet
    /// returns to idle rather than celebrating forever.
    public func settledState(after gesture: AnimationTrack, from state: AgentState) -> AgentState {
        if state == .completed { return .idle }
        return state
    }
}
