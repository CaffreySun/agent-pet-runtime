import Foundation

/// Which published atlas contract a pet package conforms to.
///
/// V1 is the documented OpenAI/Codex baseline. V2 exists in the wild
/// (`spriteVersionNumber: 2`, 1536x2288, 8x11) and must load rather than be
/// rejected — users already have such pets installed. V1's nine rows are a
/// prefix of V2's eleven, so V2 degrades cleanly: rows 0-8 play, rows 9-10
/// are reserved.
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
        case .openAICodexV1: return "OpenAI Codex V1"
        case .openAICodexV2: return "OpenAI Codex V2"
        }
    }

    /// Whether every atlas row is driven by this runtime today.
    /// V2 carries two rows whose meaning is not yet confirmed.
    public var isFullySupported: Bool { self == .openAICodexV1 }

    /// Resolve a profile from an atlas pixel size.
    public static func matching(width: Int, height: Int) -> CompatibilityProfile? {
        allCases.first { $0.atlasWidth == width && $0.atlasHeight == height }
    }

    /// Tracks by atlas row index.
    public var tracks: [AnimationTrack] {
        var all: [AnimationTrack] = [
            AnimationTrack(name: "idle",          row: 0, frameCount: 6, fps: 8,  loop: .loop),
            AnimationTrack(name: "running-right", row: 1, frameCount: 8, fps: 12, loop: .loop),
            AnimationTrack(name: "running-left",  row: 2, frameCount: 8, fps: 12, loop: .loop),
            AnimationTrack(name: "waving",        row: 3, frameCount: 4, fps: 8,  loop: .once),
            AnimationTrack(name: "jumping",       row: 4, frameCount: 5, fps: 12, loop: .once),
            AnimationTrack(name: "failed",        row: 5, frameCount: 8, fps: 10, loop: .loop),
            AnimationTrack(name: "waiting",       row: 6, frameCount: 6, fps: 6,  loop: .loop),
            AnimationTrack(name: "running",       row: 7, frameCount: 6, fps: 12, loop: .loop),
            AnimationTrack(name: "review",        row: 8, frameCount: 6, fps: 8,  loop: .loop),
        ]
        if self == .openAICodexV2 {
            // Rows 9 and 10 exist in the V2 geometry but their animation
            // contract is unconfirmed. Declared with zero frames so the
            // validator never expects content in them and the resolver never
            // selects them.
            all.append(AnimationTrack(name: "reserved-9",  row: 9,  frameCount: 0, fps: 8, loop: .loop))
            all.append(AnimationTrack(name: "reserved-10", row: 10, frameCount: 0, fps: 8, loop: .loop))
        }
        return all
    }

    public func track(named name: String) -> AnimationTrack? {
        tracks.first { $0.name == name }
    }

    public func track(atRow row: Int) -> AnimationTrack? {
        tracks.first { $0.row == row }
    }

    /// Rows the validator requires content in. Reserved rows are exempt.
    public var requiredRows: [Int] {
        tracks.filter { $0.frameCount > 0 }.map(\.row)
    }

    public var kind: (Int) -> TrackKind {
        { row in
            switch row {
            case 0, 5, 6, 7: return .state
            case 3, 4, 8:    return .gesture
            case 1, 2:       return .locomotion
            default:         return .reserved
            }
        }
    }
}
