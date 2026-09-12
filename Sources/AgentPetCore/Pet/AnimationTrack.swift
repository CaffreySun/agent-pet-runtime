import Foundation

public enum LoopMode: String, Codable, Sendable {
    /// Repeat indefinitely while the track is active.
    case loop
    /// Play through once, then hand control back to the state track.
    case once
}

/// One animation row in a sprite atlas.
///
/// Frame count is part of the published OpenAI/Codex contract; fps and loop
/// mode are *not* — they are design values this runtime chooses, so they live
/// in the compatibility profile and can be retuned without touching the
/// geometry contract.
public struct AnimationTrack: Hashable, Sendable {
    public let name: String
    public let row: Int
    public let frameCount: Int
    public let fps: Double
    public let loop: LoopMode

    public init(name: String, row: Int, frameCount: Int, fps: Double, loop: LoopMode) {
        self.name = name
        self.row = row
        self.frameCount = frameCount
        self.fps = fps
        self.loop = loop
    }

    /// Wall-clock duration of one pass through the row.
    public var duration: TimeInterval {
        Double(frameCount) / fps
    }
}

/// Which kind of input drives a track.
///
/// The original spec implicitly treated all nine atlas rows as agent-state
/// rows. They are not: only four of them track `AgentState`.
public enum TrackKind: Sendable {
    /// Driven by `AgentState`.
    case state
    /// Triggered by a transient event; plays once then yields.
    case gesture
    /// Driven by on-screen movement, independent of any agent.
    case locomotion
    /// Present in the atlas but not driven in v0.1.
    case reserved
}

public extension AgentState {
    /// The atlas row this state maps to.
    ///
    /// `waitingInput` and `waitingApproval` deliberately share one row — the
    /// atlas has only one `waiting` track. The distinction is surfaced in the
    /// UI badge, not the animation.
    var animationTrackName: String {
        switch self {
        case .idle, .paused, .unknown: return "idle"
        case .running:                 return "running"
        case .waitingInput,
             .waitingApproval:         return "waiting"
        case .completed:               return "waving"
        case .failed:                  return "failed"
        }
    }
}
