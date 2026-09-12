import Foundation

/// Checks a decoded atlas against its compatibility profile.
///
/// The rule that is easy to miss — and that the original spec never stated —
/// is that cells past a row's frame count must be *fully transparent*. A row
/// with six frames occupies six of eight columns; if columns 6 and 7 retain
/// pixels, playback of the shorter `waving` row (four frames) will flash
/// fragments of whatever was left there.
public struct AtlasValidator: Sendable {
    /// Alpha at or below this counts as invisible. Slightly above zero because
    /// chroma-keying and resampling leave near-zero residue.
    public var alphaThreshold: UInt8

    public init(alphaThreshold: UInt8 = 8) {
        self.alphaThreshold = alphaThreshold
    }

    public func validate(_ bitmap: AtlasBitmap, profile: CompatibilityProfile) -> ValidationReport {
        var report = ValidationReport()

        if bitmap.width != profile.atlasWidth || bitmap.height != profile.atlasHeight {
            report.add("atlas", .error,
                       "atlas is \(bitmap.width)x\(bitmap.height), expected "
                       + "\(profile.atlasWidth)x\(profile.atlasHeight) for \(profile.displayName)")
            // Every cell check below would be measuring the wrong rectangles.
            return report
        }

        if !bitmap.hasAlphaChannel {
            report.add("atlas", .error, "atlas has no alpha channel; unused cells cannot be transparent")
            return report
        }

        let atlas = SpriteAtlas(profile: profile, width: bitmap.width, height: bitmap.height)

        for track in profile.tracks {
            guard track.frameCount > 0 else { continue }

            for rect in atlas.rects(for: track) {
                if bitmap.isCellEmpty(rect, alphaThreshold: alphaThreshold) {
                    report.add("atlas", .error,
                               "row \(track.row) (\(track.name)) has an empty frame in column \(rect.x / profile.cellWidth)")
                }
            }

            for rect in atlas.unusedRects(for: track) {
                if !bitmap.isCellEmpty(rect, alphaThreshold: alphaThreshold) {
                    report.add("atlas", .error,
                               "row \(track.row) (\(track.name)) leaves pixels in unused column "
                               + "\(rect.x / profile.cellWidth); these will bleed into playback")
                }
            }
        }

        if !profile.isFullySupported {
            report.add("atlas", .warning,
                       "\(profile.displayName) is partially supported: rows "
                       + "\(profile.requiredRows.count)..<\(profile.rows) are not played")
        }

        return report
    }
}
