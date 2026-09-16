import Foundation

public enum LoopMode: String, Codable, Sendable {
    /// Repeat while the track is active.
    case loop
    /// Play through once, then hand control back.
    case once
    /// Not animated: one pose, chosen by direction rather than by time.
    case staticPose
}

/// What drives a track.
public enum TrackKind: String, Codable, Sendable, CaseIterable {
    /// Driven by `AgentState` — what the agent is doing.
    case state
    /// A one-shot gesture triggered by an event.
    case gesture
    /// Locomotion, driven by the pet moving on screen.
    case locomotion
    /// A gaze pose, driven by where the pointer is.
    case look
}

/// One animation row in a sprite atlas.
///
/// Durations are **per frame**, not a frame rate. The published contract gives
/// explicit millisecond timings for every frame, and they are not uniform:
/// `idle` runs `280, 110, 110, 140, 140, 320`, holding its first and last
/// frames nearly three times as long as its middle ones. A single fps cannot
/// express that, and approximating it makes the pet breathe wrong.
///
/// The idle row is also the one place Codex's tables and this profile
/// disagree: Codex multiplies those six durations by six (the app's
/// `ger = her.map(frameDurationMs * 6)`, the TUI's `idle_animation`), which
/// makes a breath six seconds long. That version is a settle tail there — a
/// thing glimpsed after a state, not the resting face of the pet — and a
/// desktop pet is idle most of the time, so this profile plays the authored
/// timings.
///
/// `repeats` is the other half of Codex's playback shape, and it separates
/// two kinds of state. A **moment** — a task finishing, a failure — plays its
/// row `repeats` times and then hands over to the idle row, which loops from
/// there; that is Codex's `[...row, ...row, ...row, ...idle]` with
/// `loopStartIndex` at the idle segment. A **condition** — working, waiting on
/// a human — has `repeats == 1` and loops its row for as long as it lasts,
/// because a condition outlives three passes by minutes, and settling into a
/// calm breath while the agent is plainly still working reads as "asleep
/// already".
public struct AnimationTrack: Hashable, Sendable {
    public let name: String
    public let row: Int
    /// How long each frame is shown, in order.
    public let frameDurations: [TimeInterval]
    public let loop: LoopMode
    public let kind: TrackKind
    /// How many times the row plays before the resolver settles into idle.
    public let repeats: Int

    public init(
        name: String,
        row: Int,
        frameDurations: [TimeInterval],
        loop: LoopMode,
        kind: TrackKind,
        repeats: Int = 1
    ) {
        self.name = name
        self.row = row
        self.frameDurations = frameDurations
        self.loop = loop
        self.kind = kind
        self.repeats = max(1, repeats)
    }

    /// Convenience for the contract's common shape: every frame the same
    /// duration except the last, which is held longer.
    public init(
        name: String,
        row: Int,
        frameCount: Int,
        frameDuration: TimeInterval,
        finalFrameDuration: TimeInterval,
        loop: LoopMode,
        kind: TrackKind,
        repeats: Int = 1
    ) {
        let middle = Array(repeating: frameDuration, count: max(0, frameCount - 1))
        self.init(
            name: name,
            row: row,
            frameDurations: middle + [finalFrameDuration],
            loop: loop,
            kind: kind,
            repeats: repeats
        )
    }

    public var frameCount: Int { frameDurations.count }

    /// One full pass through the row.
    public var duration: TimeInterval { frameDurations.reduce(0, +) }

    /// Which frame is showing `elapsed` seconds in.
    ///
    /// Returns the frame index and whether a one-shot has run past its end.
    public func frameIndex(at elapsed: TimeInterval) -> (index: Int, finished: Bool) {
        guard !frameDurations.isEmpty else { return (0, true) }

        let total = duration
        guard total > 0 else { return (0, loop == .loop ? false : true) }

        var offset = max(0, elapsed)

        switch loop {
        case .staticPose:
            return (0, false)
        case .once:
            guard offset < total else { return (frameCount - 1, true) }
        case .loop:
            // Wrap first so a very long elapsed does not walk the array.
            offset = offset.truncatingRemainder(dividingBy: total)
        }

        var accumulated: TimeInterval = 0
        for (index, frameDuration) in frameDurations.enumerated() {
            accumulated += frameDuration
            if offset < accumulated { return (index, false) }
        }
        return (frameCount - 1, loop == .once)
    }
}

/// One of the sixteen clockwise gaze poses in a V2 atlas.
///
/// Rows 9 and 10 are not spare capacity: together they form a continuous
/// sixteen-step look loop at 22.5° intervals. `000` is straight up, not
/// forward — the pet always faces the viewer, and these rows only turn its
/// gaze.
public enum LookDirection {

    public static let sectorCount = 16
    public static let sectorSize = 360.0 / Double(sectorCount)

    /// Which atlas cell shows a gaze at this angle.
    ///
    /// `angle` is clockwise from up, matching the contract's own labelling.
    /// The half-sector offset puts each pose at the centre of its sector, so
    /// pointing straight up selects `000` rather than straddling two poses.
    public static func cell(forAngle angle: Double) -> (row: Int, column: Int) {
        let normalized = angle.truncatingRemainder(dividingBy: 360)
        let positive = normalized < 0 ? normalized + 360 : normalized
        let sector = Int(((positive + sectorSize / 2) / sectorSize).rounded(.down)) % sectorCount
        return cell(forSector: sector)
    }

    public static func cell(forSector sector: Int) -> (row: Int, column: Int) {
        let clamped = ((sector % sectorCount) + sectorCount) % sectorCount
        return (row: clamped < 8 ? 9 : 10, column: clamped % 8)
    }

    /// Angle from `origin` to `target`, clockwise from up.
    ///
    /// Both points are in **AppKit screen coordinates** — the space
    /// `NSEvent.mouseLocation` and `NSWindow.frame` live in, where the origin
    /// is the bottom left of the primary display and **y grows upward**. Up is
    /// therefore `+dy`, and this is the space the pet is placed in, so a caller
    /// can hand over a window's centre and the pointer unchanged.
    ///
    /// Codex's own code computes this angle in DOM coordinates, where y grows
    /// *downward* (`atan2(dx, -dy)`); the sign of `dy` is the whole difference,
    /// and getting it backwards mirrors the pet's gaze vertically — it looks
    /// down when the pointer is above it — while leaving left and right
    /// correct, which is quiet enough to go unnoticed. `LookDirectionTests`
    /// pins the space.
    public static func angle(from origin: CGPoint, to target: CGPoint) -> Double {
        let dx = target.x - origin.x
        let dy = target.y - origin.y
        let radians = atan2(dx, dy)
        let degrees = radians * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
    }
}
