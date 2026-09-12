import Foundation

/// A pixel rectangle in atlas coordinates, origin at top-left.
public struct CellRect: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var pixelCount: Int { width * height }
}

/// Slices an atlas into animation cells. Geometry only — knows nothing about
/// pixels, files, or agents.
public struct SpriteAtlas: Sendable, Equatable {
    public let profile: CompatibilityProfile
    public let width: Int
    public let height: Int

    public init(profile: CompatibilityProfile, width: Int, height: Int) {
        self.profile = profile
        self.width = width
        self.height = height
    }

    public init(profile: CompatibilityProfile) {
        self.init(profile: profile, width: profile.atlasWidth, height: profile.atlasHeight)
    }

    public var columns: Int { profile.columns }
    public var rows: Int { profile.rows }

    public func contains(row: Int, column: Int) -> Bool {
        row >= 0 && row < rows && column >= 0 && column < columns
    }

    /// Throws rather than returning nil: an out-of-range access is a
    /// programming error, not a runtime condition to paper over.
    public func rect(row: Int, column: Int) throws -> CellRect {
        guard contains(row: row, column: column) else {
            throw AtlasError.cellOutOfBounds(row: row, column: column, rows: rows, columns: columns)
        }
        return CellRect(
            x: column * profile.cellWidth,
            y: row * profile.cellHeight,
            width: profile.cellWidth,
            height: profile.cellHeight
        )
    }

    /// Every cell a track will actually play.
    public func rects(for track: AnimationTrack) -> [CellRect] {
        guard track.frameCount > 0 else { return [] }
        return (0..<track.frameCount).compactMap { try? rect(row: track.row, column: $0) }
    }

    /// Cells a track must leave empty: past the frame count, up to the last
    /// column. The published contract requires these to be fully transparent —
    /// otherwise the leftovers of a shorter row bleed into playback.
    public func unusedRects(for track: AnimationTrack) -> [CellRect] {
        let first = track.frameCount
        guard first < columns else { return [] }
        return (first..<columns).compactMap { try? rect(row: track.row, column: $0) }
    }

    public func contains(_ rect: CellRect) -> Bool {
        rect.x >= 0 && rect.y >= 0
            && rect.x + rect.width <= width
            && rect.y + rect.height <= height
    }
}

public enum AtlasError: Error, Equatable, Sendable {
    case cellOutOfBounds(row: Int, column: Int, rows: Int, columns: Int)
    case rowOutOfBounds(Int, rows: Int)
}
