import Foundation

/// Checks a decoded atlas against its compatibility profile.
///
/// ## Severity is calibrated to this runtime, not to the authoring toolchain
///
/// OpenAI's `validate_atlas.py` is an *authoring* gate: it fails a build on any
/// stray pixel in a surplus cell. This validator is an *install* gate, and has
/// to answer a different question — will this pet play correctly here?
///
/// The difference matters. This renderer only ever samples columns
/// `0..<frameCount` (see `SpriteAtlas.rects(for:)`), so pixels left in a
/// surplus column are *unreachable*: they cannot bleed into playback. They are
/// a deviation from the authoring contract, not a defect. Real packages in
/// `~/.codex/pets/` do contain such leftovers, and rejecting them would refuse
/// pets that work perfectly well — the exact failure this project's review
/// warned against.
///
/// So surplus-cell residue is reported as a warning, while genuinely broken
/// content — an empty frame, a wrong-sized atlas, no alpha channel — stays an
/// error.
public struct AtlasValidator: Sendable {
    /// Alpha above this counts as visible. Zero, matching the official tool,
    /// so surplus residue is detected as thoroughly as upstream would.
    public var alphaThreshold: UInt8

    /// A used cell with fewer visible pixels than this is suspiciously sparse.
    /// Mirrors `validate_atlas.py`'s `--min-used-pixels` default.
    public var minUsedPixels: Int

    public init(alphaThreshold: UInt8 = 0, minUsedPixels: Int = 50) {
        self.alphaThreshold = alphaThreshold
        self.minUsedPixels = minUsedPixels
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
                let column = rect.x / profile.cellWidth
                let pixels = bitmap.opaquePixelCount(in: rect, alphaThreshold: alphaThreshold)

                if pixels == 0 {
                    report.add("atlas", .error,
                               "row \(track.row) (\(track.name)) has an empty frame in column \(column)")
                } else if pixels < minUsedPixels {
                    report.add("atlas", .warning,
                               "row \(track.row) (\(track.name)) column \(column) has only "
                               + "\(pixels) visible pixels; it may render blank")
                }
            }
        }

        // Only rows with surplus columns are checked for residue. The look
        // rows use all eight columns, so they have none — flagging content
        // there would report a correctly drawn gaze pose as a defect.
        let cleanRows = Set(profile.rowsRequiringCleanSurplus)
        for track in profile.tracks where cleanRows.contains(track.row) {
            for rect in atlas.unusedRects(for: track) {
                let pixels = bitmap.opaquePixelCount(in: rect, alphaThreshold: alphaThreshold)
                if pixels > 0 {
                    report.add("atlas", .warning,
                               "row \(track.row) (\(track.name)) leaves \(pixels) pixels in unused "
                               + "column \(rect.x / profile.cellWidth); this renderer never samples "
                               + "that column, but it deviates from the published contract")
                }
            }
        }

        return report
    }
}
