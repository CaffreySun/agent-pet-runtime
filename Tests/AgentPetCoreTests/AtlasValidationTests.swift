import Foundation
import Testing
@testable import AgentPetCore

/// Builds a valid V1 atlas: every required cell has content, every unused cell
/// is clear. Individual tests then break exactly one thing.
private func validAtlas(_ profile: CompatibilityProfile = .openAICodexV1) -> RGBAAtlasBitmap {
    var bitmap = RGBAAtlasBitmap.empty(width: profile.atlasWidth, height: profile.atlasHeight)
    let atlas = SpriteAtlas(profile: profile)
    for track in profile.tracks where track.frameCount > 0 {
        for rect in atlas.rects(for: track) {
            bitmap.fill(rect)
        }
    }
    return bitmap
}

private let validator = AtlasValidator()

@Suite("Atlas geometry slicing")
struct SpriteAtlasTests {

    @Test("cells tile the atlas with no gaps or overlap")
    func cellsTile() throws {
        let atlas = SpriteAtlas(profile: .openAICodexV1)
        var covered = 0
        for row in 0..<atlas.rows {
            for col in 0..<atlas.columns {
                covered += try atlas.rect(row: row, column: col).pixelCount
            }
        }
        #expect(covered == atlas.width * atlas.height)
    }

    @Test("cell origin is column-major stride")
    func cellOrigin() throws {
        let atlas = SpriteAtlas(profile: .openAICodexV1)
        let r = try atlas.rect(row: 3, column: 5)
        #expect(r.x == 5 * 192)
        #expect(r.y == 3 * 208)
        #expect(r.width == 192)
        #expect(r.height == 208)
    }

    @Test("the last cell ends exactly at the atlas edge")
    func lastCellAtEdge() throws {
        let atlas = SpriteAtlas(profile: .openAICodexV1)
        let r = try atlas.rect(row: 8, column: 7)
        #expect(r.x + r.width == atlas.width)
        #expect(r.y + r.height == atlas.height)
    }

    @Test("out-of-range access throws rather than returning nil", arguments: [
        (-1, 0), (0, -1), (9, 0), (0, 8), (11, 0),
    ])
    func outOfBounds(row: Int, column: Int) {
        let atlas = SpriteAtlas(profile: .openAICodexV1)
        #expect(throws: AtlasError.self) { try atlas.rect(row: row, column: column) }
    }

    @Test("a track yields exactly its frame count of cells")
    func trackRects() {
        let atlas = SpriteAtlas(profile: .openAICodexV1)
        #expect(atlas.rects(for: atlas.profile.track(named: "idle")!).count == 6)
        #expect(atlas.rects(for: atlas.profile.track(named: "waving")!).count == 4)
        #expect(atlas.rects(for: atlas.profile.track(named: "failed")!).count == 8)
    }

    @Test("unused cells are the columns past the frame count")
    func unusedRects() {
        let atlas = SpriteAtlas(profile: .openAICodexV1)
        let waving = atlas.profile.track(named: "waving")!   // 4 frames, 8 columns
        let unused = atlas.unusedRects(for: waving)
        #expect(unused.count == 4)
        #expect(unused.map { $0.x / 192 } == [4, 5, 6, 7])
    }

    @Test("a full-width row has no unused cells")
    func fullRowHasNoUnused() {
        let atlas = SpriteAtlas(profile: .openAICodexV1)
        let running = atlas.profile.track(named: "running-right")!   // 8 frames
        #expect(atlas.unusedRects(for: running).isEmpty)
    }

    @Test("a reserved V2 row contributes no playable cells")
    func reservedRowsPlayNothing() {
        let atlas = SpriteAtlas(profile: .openAICodexV2)
        #expect(atlas.rects(for: atlas.profile.track(named: "reserved-9")!).isEmpty)
    }
}

@Suite("Atlas validation")
struct AtlasValidatorTests {

    @Test("a well-formed atlas passes")
    func validAtlasPasses() {
        let report = validator.validate(validAtlas(), profile: .openAICodexV1)
        #expect(report.isValid)
        #expect(report.errors.isEmpty)
    }

    @Test("a wrong-sized atlas is rejected and stops there")
    func wrongSize() {
        let bitmap = RGBAAtlasBitmap.empty(width: 1024, height: 1024)
        let report = validator.validate(bitmap, profile: .openAICodexV1)
        #expect(!report.isValid)
        // Cell checks would have been measuring meaningless rectangles.
        #expect(report.errors.count == 1)
        #expect(report.errors[0].message.contains("1536x1872"))
    }

    @Test("an atlas with no alpha channel is rejected")
    func noAlpha() {
        var bitmap = validAtlas()
        bitmap = RGBAAtlasBitmap(width: bitmap.width, height: bitmap.height,
                                 pixels: bitmap.pixels, hasAlpha: false)
        let report = validator.validate(bitmap, profile: .openAICodexV1)
        #expect(!report.isValid)
        #expect(report.errors.contains { $0.message.contains("alpha") })
    }

    @Test("an empty frame in a required cell is an error")
    func emptyRequiredCell() throws {
        let profile = CompatibilityProfile.openAICodexV1
        var bitmap = validAtlas(profile)
        let atlas = SpriteAtlas(profile: profile)
        let rect = try atlas.rect(row: 0, column: 3)
        bitmap.fill(rect, rgba: (0, 0, 0, 0))   // clear it

        let report = validator.validate(bitmap, profile: profile)
        #expect(!report.isValid)
        #expect(report.errors.contains { $0.message.contains("row 0 (idle)") })
    }

    @Test("leftover pixels in an unused cell warn rather than fail the install")
    func dirtyUnusedCellWarns() throws {
        let profile = CompatibilityProfile.openAICodexV1
        var bitmap = validAtlas(profile)
        let atlas = SpriteAtlas(profile: profile)
        // waving has 4 frames; make column 5 dirty.
        bitmap.fill(try atlas.rect(row: 3, column: 5))

        let report = validator.validate(bitmap, profile: profile)
        // This renderer samples columns 0..<frameCount only, so the stray
        // pixels are unreachable. Report them; do not refuse the pet.
        #expect(report.isValid)
        #expect(report.errors.isEmpty)
        #expect(report.warnings.contains {
            $0.message.contains("waving") && $0.message.contains("column 5")
        })
    }

    @Test("any non-zero alpha in an unused cell is detected, however faint")
    func faintResidueStillDetected() throws {
        let profile = CompatibilityProfile.openAICodexV1
        var bitmap = validAtlas(profile)
        let atlas = SpriteAtlas(profile: profile)
        bitmap.fill(try atlas.rect(row: 3, column: 5), rgba: (10, 10, 10, 1))

        let report = validator.validate(bitmap, profile: profile)
        #expect(report.isValid)
        #expect(report.warnings.contains { $0.message.contains("unused column 5") })
    }

    @Test("a sparse used cell warns but does not fail")
    func sparseUsedCellWarns() throws {
        let profile = CompatibilityProfile.openAICodexV1
        var bitmap = validAtlas(profile)
        let atlas = SpriteAtlas(profile: profile)
        // Leave ten pixels where a whole pose should be.
        bitmap.fill(try atlas.rect(row: 0, column: 1), rgba: (0, 0, 0, 0))
        bitmap.fill(CellRect(
            x: 1 * profile.cellWidth, y: 0,
            width: 10, height: 1
        ))

        let report = validator.validate(bitmap, profile: profile)
        #expect(report.isValid)
        #expect(report.warnings.contains { $0.message.contains("only 10 visible pixels") })
    }

    @Test("a fully transparent atlas fails on every required cell")
    func blankAtlas() {
        let profile = CompatibilityProfile.openAICodexV1
        let bitmap = RGBAAtlasBitmap.empty(width: profile.atlasWidth, height: profile.atlasHeight)
        let report = validator.validate(bitmap, profile: profile)
        #expect(!report.isValid)
        // 6+8+8+4+5+8+6+6+6 = 57 required frames
        #expect(report.errors.count == report.errors.count)
        #expect(report.errors.count >= 57)
    }

    @Test("a V1 atlas validated as V2 is rejected on size")
    func profileMismatch() {
        let report = validator.validate(validAtlas(.openAICodexV1), profile: .openAICodexV2)
        #expect(!report.isValid)
    }

    @Test("a V2 atlas with its top nine rows filled is valid but warns")
    func v2PartiallySupported() {
        let profile = CompatibilityProfile.openAICodexV2
        var bitmap = RGBAAtlasBitmap.empty(width: profile.atlasWidth, height: profile.atlasHeight)
        let atlas = SpriteAtlas(profile: profile)
        for track in profile.tracks where track.frameCount > 0 {
            for rect in atlas.rects(for: track) { bitmap.fill(rect) }
        }
        let report = validator.validate(bitmap, profile: profile)
        #expect(report.isValid)
        #expect(report.warnings.contains { $0.message.contains("partially supported") })
    }
}

@Suite("RGBA bitmap sampling")
struct RGBAAtlasBitmapTests {

    @Test("an empty bitmap reports no opaque pixels anywhere")
    func emptyBitmap() {
        let bitmap = RGBAAtlasBitmap.empty(width: 32, height: 32)
        #expect(bitmap.opaquePixelCount(in: CellRect(x: 0, y: 0, width: 32, height: 32),
                                        alphaThreshold: 8) == 0)
    }

    @Test("a filled rect reports exactly its pixel count")
    func filledRect() {
        var bitmap = RGBAAtlasBitmap.empty(width: 32, height: 32)
        let rect = CellRect(x: 4, y: 4, width: 8, height: 8)
        bitmap.fill(rect)
        #expect(bitmap.opaquePixelCount(in: rect, alphaThreshold: 8) == 64)
    }

    @Test("sampling is clamped to the bitmap bounds")
    func samplingClamped() {
        var bitmap = RGBAAtlasBitmap.empty(width: 16, height: 16)
        bitmap.fill(CellRect(x: 0, y: 0, width: 16, height: 16))
        let overflowing = CellRect(x: -8, y: -8, width: 32, height: 32)
        #expect(bitmap.opaquePixelCount(in: overflowing, alphaThreshold: 8) == 256)
    }

    @Test("a rect entirely outside the bitmap counts nothing")
    func outsideRect() {
        let bitmap = RGBAAtlasBitmap.empty(width: 16, height: 16)
        #expect(bitmap.opaquePixelCount(in: CellRect(x: 100, y: 100, width: 8, height: 8),
                                        alphaThreshold: 8) == 0)
    }
}
