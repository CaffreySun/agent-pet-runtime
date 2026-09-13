import Foundation

/// Which published atlas contract a pet package conforms to.
///
/// V2 is the *primary* format — the toolchain hatches every new pet as
/// `1536x2288`, and its own reference calls the V1 atlas "an intermediate
/// assembly artifact only". V1 remains fully supported because packages in the
/// wild use it, but it is the legacy shape, not the baseline.
public enum CompatibilityProfile: String, Codable, Sendable, CaseIterable {
    case openAICodexV1
    case openAICodexV2

    public var columns: Int { 8 }
    public var cellWidth: Int { 192 }
    public var cellHeight: Int { 208 }

    public var rows: Int {
        switch self {
        case .openAICodexV1: return 9
        case .openAICodexV2: return 11
        }
    }

    public var atlasWidth: Int { columns * cellWidth }
    public var atlasHeight: Int { rows * cellHeight }

    public var displayName: String {
        switch self {
        case .openAICodexV1: return "Codex V1"
        case .openAICodexV2: return "Codex V2"
        }
    }

    /// V2 adds the sixteen gaze poses; everything else is identical.
    public var hasLookDirections: Bool { self == .openAICodexV2 }

    /// Rows 9 and 10 carry look poses, so they are used — unlike the surplus
    /// columns of a short row, which must stay clear.
    public var lookRows: [Int] { hasLookDirections ? [9, 10] : [] }

    public static func matching(width: Int, height: Int) -> CompatibilityProfile? {
        allCases.first { $0.atlasWidth == width && $0.atlasHeight == height }
    }

    // MARK: - Tracks

    /// How many times a *moment's* row plays before the pet settles into
    /// idle. Codex's playback shape, in both the app and the TUI.
    private static let momentRepeats = 3

    /// The nine standard rows, with the contract's own per-frame timings.
    ///
    /// Every value below is copied from the published animation-row table. The
    /// final frame of most rows is held longer, which is what gives a gesture a
    /// beat to land on rather than ending abruptly.
    public var tracks: [AnimationTrack] {
        var all: [AnimationTrack] = [
            // 280, 110, 110, 140, 140, 320 — the middle frames are quick and
            // the ends are held, which is a breath, not an even cycle.
            //
            // Codex's own tables multiply these six times over, but that slow
            // version is only ever glimpsed: in the app it is the settle tail
            // that follows a state, and the pet that sits on the desktop here
            // is idle most of the time. Playing a resting pet at 0.6 frames a
            // second reads as broken, not calm — reported from use on
            // 2026-09-13, after this runtime had ported the slow version.
            AnimationTrack(
                name: "idle", row: 0,
                frameDurations: [0.280, 0.110, 0.110, 0.140, 0.140, 0.320],
                loop: .loop, kind: .state
            ),
            AnimationTrack(
                name: "running-right", row: 1, frameCount: 8,
                frameDuration: 0.120, finalFrameDuration: 0.220,
                loop: .loop, kind: .locomotion
            ),
            AnimationTrack(
                name: "running-left", row: 2, frameCount: 8,
                frameDuration: 0.120, finalFrameDuration: 0.220,
                loop: .loop, kind: .locomotion
            ),
            AnimationTrack(
                name: "waving", row: 3, frameCount: 4,
                frameDuration: 0.140, finalFrameDuration: 0.280,
                loop: .once, kind: .gesture
            ),
            AnimationTrack(
                name: "jumping", row: 4, frameCount: 5,
                frameDuration: 0.140, finalFrameDuration: 0.280,
                loop: .once, kind: .gesture
            ),
            // A failure is a moment: three passes and then the idle breath,
            // which is what stops the pet holding a grimace.
            AnimationTrack(
                name: "failed", row: 5, frameCount: 8,
                frameDuration: 0.140, finalFrameDuration: 0.240,
                loop: .loop, kind: .state, repeats: Self.momentRepeats
            ),
            // Waiting is a condition: a pending approval can outlast any
            // three passes by minutes, and the pet should look like it is
            // still asking the whole time.
            AnimationTrack(
                name: "waiting", row: 6, frameCount: 6,
                frameDuration: 0.150, finalFrameDuration: 0.260,
                loop: .loop, kind: .state
            ),
            // Active task work, not foot-running — despite the name. Also a
            // condition: looping for as long as the agent works is the point.
            AnimationTrack(
                name: "running", row: 7, frameCount: 6,
                frameDuration: 0.120, finalFrameDuration: 0.220,
                loop: .loop, kind: .state
            ),
            // Focused inspection of finished work — Codex plays this row when
            // a turn completes, which is what our `completed` state means. A
            // moment like `failed`.
            AnimationTrack(
                name: "review", row: 8, frameCount: 6,
                frameDuration: 0.150, finalFrameDuration: 0.280,
                loop: .loop, kind: .state, repeats: Self.momentRepeats
            ),
        ]

        if hasLookDirections {
            // A gaze pose is selected by angle, never by elapsed time, so the
            // durations here exist only so the geometry stays uniform.
            all.append(AnimationTrack(
                name: "look-a", row: 9, frameCount: 8,
                frameDuration: 0.1, finalFrameDuration: 0.1,
                loop: .staticPose, kind: .look
            ))
            all.append(AnimationTrack(
                name: "look-b", row: 10, frameCount: 8,
                frameDuration: 0.1, finalFrameDuration: 0.1,
                loop: .staticPose, kind: .look
            ))
        }

        return all
    }

    public func track(named name: String) -> AnimationTrack? {
        tracks.first { $0.name == name }
    }

    public func track(atRow row: Int) -> AnimationTrack? {
        tracks.first { $0.row == row }
    }

    /// Rows the validator requires content in. Every standard row, plus the
    /// look rows when the profile has them; all sixteen gaze poses are used.
    public var requiredRows: [Int] {
        tracks.filter { $0.frameCount > 0 }.map(\.row)
    }

    /// Rows whose surplus cells must be transparent.
    ///
    /// The look rows are excluded: all eight of their columns are used, so
    /// there is no surplus to leave clear.
    public var rowsRequiringCleanSurplus: [Int] {
        tracks
            .filter { $0.kind != .look && $0.frameCount > 0 }
            .map(\.row)
    }
}
