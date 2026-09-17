import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AgentPetCore

private enum ScratchError: Error {
    case couldNotWriteImage
}

/// A package folder on disk, with whatever the test wants wrong with it.
@discardableResult
private func writePackage(
    in root: URL,
    folder: String,
    manifestJSON: String,
    sheet: (width: Int, height: Int)? = (1536, 1872),
    sheetsNamed name: String = "spritesheet.webp",
    extraFiles: [String] = []
) throws -> URL {
    let package = root.appendingPathComponent(folder)
    try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
    try Data(manifestJSON.utf8).write(to: package.appendingPathComponent("pet.json"))
    if let sheet {
        try writeImage(width: sheet.width, height: sheet.height,
                       to: package.appendingPathComponent(name))
    }
    for name in extraFiles {
        try Data("x".utf8).write(to: package.appendingPathComponent(name))
    }
    return package
}

/// A real image file: the loader reads dimensions from the header, so a package
/// with a declared version can only be judged against a sheet that exists.
private func writeImage(width: Int, height: Int, to url: URL) throws {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let image = context.makeImage(),
       let destination = CGImageDestinationCreateWithURL(
           url as CFURL, "public.png" as CFString, 1, nil
       )
    else { throw ScratchError.couldNotWriteImage }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw ScratchError.couldNotWriteImage }
}

private func makeScratch() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pet-library-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func v1Manifest(id: String, version: Int? = nil) -> String {
    let version = version.map { ",\"spriteVersionNumber\":\($0)" } ?? ""
    return #"{"id":"\#(id)","displayName":"\#(id)","spritesheetPath":"spritesheet.webp"\#(version)}"#
}

private func petsSource(_ root: URL) -> PetLibraryScanner.Source {
    PetLibraryScanner.Source(directory: root, manifest: PetPackageLoader.manifestFileName)
}

@Suite("Pet library scanning")
struct PetLibraryScannerTests {

    @Test("a mixed library lists both profiles and reports nothing")
    func mixedLibrary() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        try writePackage(in: root, folder: "plain-v1", manifestJSON: v1Manifest(id: "plain-v1"))
        try writePackage(in: root, folder: "declared-v1",
                         manifestJSON: v1Manifest(id: "declared-v1", version: 1))
        try writePackage(in: root, folder: "by-size-v2",
                         manifestJSON: v1Manifest(id: "by-size-v2"), sheet: (1536, 2288))
        try writePackage(in: root, folder: "declared-v2",
                         manifestJSON: v1Manifest(id: "declared-v2", version: 2), sheet: (1536, 2288))

        let result = PetLibraryScanner.scan(sources: [petsSource(root)])

        #expect(result.skipped.isEmpty)
        #expect(result.entries.map(\.id).sorted() == ["by-size-v2", "declared-v1", "declared-v2", "plain-v1"])
        #expect(result.entries.first { $0.id == "plain-v1" }?.definition.profile == .openAICodexV1)
        #expect(result.entries.first { $0.id == "declared-v2" }?.definition.profile == .openAICodexV2)
    }

    @Test("a declared version that contradicts the sheet is reported, not dropped")
    func contradictoryVersionIsReported() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        // Declares V2, ships the V1 geometry — the one way to be refused that a
        // user can neither see nor guess.
        try writePackage(in: root, folder: "says-two-is-one",
                         manifestJSON: v1Manifest(id: "says-two-is-one", version: 2))

        let result = PetLibraryScanner.scan(sources: [petsSource(root)])

        #expect(result.entries.isEmpty)
        #expect(result.skipped.count == 1)
        let skip = try #require(result.skipped.first)
        #expect(skip.name == "says-two-is-one")
        #expect(skip.reason.contains("openAICodexV2"), "reason was: \(skip.reason)")
        #expect(skip.reason.contains("1536x1872"), "reason was: \(skip.reason)")
        // A reason, not a Swift description of an enum.
        #expect(!skip.reason.contains("malformedJSON"), "reason was: \(skip.reason)")
    }

    @Test("a manifest whose fields have the wrong types is reported")
    func wrongTypesAreReported() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        // `"2"`, not `2`: JSON that looks right in a diff and decodes to nothing.
        try writePackage(
            in: root, folder: "string-version",
            manifestJSON: #"{"id":"string-version","displayName":"S","spritesheetPath":"spritesheet.webp","spriteVersionNumber":"2"}"#
        )

        let result = PetLibraryScanner.scan(sources: [petsSource(root)])

        #expect(result.entries.isEmpty)
        #expect(result.skipped.count == 1)
        // The field is named: a hand-written manifest's whole problem is which
        // line to fix.
        #expect(result.skipped.first?.reason.contains("spriteVersionNumber") == true,
                "reason was: \(result.skipped.first?.reason ?? "-")")
    }

    @Test("a missing spritesheet is reported with the path the manifest asked for")
    func missingSpritesheetIsReported() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        try writePackage(in: root, folder: "no-sheet",
                         manifestJSON: v1Manifest(id: "no-sheet"), sheet: nil)

        let result = PetLibraryScanner.scan(sources: [petsSource(root)])

        #expect(result.entries.isEmpty)
        #expect(result.skipped.first?.reason.contains("spritesheet.webp") == true,
                "reason was: \(result.skipped.first?.reason ?? "-")")
    }

    @Test("a file that is not an image is reported")
    func notAnImageIsReported() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try writePackage(
            in: root, folder: "junk-sheet", manifestJSON: v1Manifest(id: "junk-sheet"), sheet: nil
        )
        try Data("not an image".utf8).write(to: package.appendingPathComponent("spritesheet.webp"))

        let result = PetLibraryScanner.scan(sources: [petsSource(root)])

        #expect(result.entries.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.reason.lowercased().contains("image") == true)
    }

    @Test("a package with an executable file is reported, not silently skipped")
    func payloadViolationIsReported() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        try writePackage(in: root, folder: "with-script",
                         manifestJSON: v1Manifest(id: "with-script"), extraFiles: ["run.sh"])

        let result = PetLibraryScanner.scan(sources: [petsSource(root)])

        #expect(result.entries.isEmpty)
        #expect(result.skipped.count == 1)
        #expect(result.skipped.first?.reason.contains("executable extension") == true,
                "reason was: \(result.skipped.first?.reason ?? "-")")
    }

    @Test("a folder with no manifest is not a pet and is not reported")
    func nonPetsAreIgnored() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("build-output"), withIntermediateDirectories: true
        )
        try Data("hello".utf8).write(
            to: root.appendingPathComponent("build-output").appendingPathComponent("README.md")
        )
        try writePackage(in: root, folder: "real-pet", manifestJSON: v1Manifest(id: "real-pet"))

        let result = PetLibraryScanner.scan(sources: [petsSource(root)])

        #expect(result.skipped.isEmpty, "a stray folder is not a broken pet")
        #expect(result.entries.map(\.id) == ["real-pet"])
    }

    @Test("a package carrying the other directory's manifest is reported")
    func wrongManifestNameIsReported() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = try writePackage(
            in: root, folder: "wrong-name", manifestJSON: v1Manifest(id: "wrong-name")
        )
        try FileManager.default.moveItem(
            at: package.appendingPathComponent("pet.json"),
            to: package.appendingPathComponent("avatar.json")
        )

        let result = PetLibraryScanner.scan(sources: [petsSource(root)])

        #expect(result.entries.isEmpty)
        #expect(result.skipped.first?.reason == "no pet.json in this folder")
    }

    @Test("a second package claiming the same id is reported, and the first is kept")
    func duplicateIDIsReported() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        try writePackage(in: root, folder: "aaa-first", manifestJSON: v1Manifest(id: "twin"))
        try writePackage(in: root, folder: "bbb-second", manifestJSON: v1Manifest(id: "twin"))

        let result = PetLibraryScanner.scan(sources: [petsSource(root)])

        #expect(result.entries.map(\.id) == ["twin"])
        #expect(result.entries.first?.root.lastPathComponent == "aaa-first")
        #expect(result.skipped.map(\.name) == ["bbb-second"])
        #expect(result.skipped.first?.reason.contains("twin") == true)
    }

    @Test("the same folder in avatars/ and pets/ is not reported as a conflict")
    func shadowedCopyIsNotAConflict() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let avatars = root.appendingPathComponent("avatars")
        let pets = root.appendingPathComponent("pets")
        try FileManager.default.createDirectory(at: avatars, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pets, withIntermediateDirectories: true)

        let legacy = try writePackage(in: avatars, folder: "shared", manifestJSON: v1Manifest(id: "shared"))
        try FileManager.default.moveItem(
            at: legacy.appendingPathComponent("pet.json"),
            to: legacy.appendingPathComponent("avatar.json")
        )
        try writePackage(in: pets, folder: "shared", manifestJSON: v1Manifest(id: "shared"))

        let result = PetLibraryScanner.scan(sources: [
            PetLibraryScanner.Source(directory: avatars,
                                     manifest: PetPackageLoader.legacyManifestFileName),
            PetLibraryScanner.Source(directory: pets,
                                     manifest: PetPackageLoader.manifestFileName),
        ])

        #expect(result.skipped.isEmpty)
        // `resolvingSymlinksInPath()`: /var is /private/var on macOS and the
        // scanner reports the path it was handed.
        #expect(result.entries.map { $0.root.resolvingSymlinksInPath().path }
                == [pets.appendingPathComponent("shared").resolvingSymlinksInPath().path])
    }

    @Test("every refusal says why, in words")
    func reasonsAreSentences() throws {
        // The point of the whole exercise: a folder the user can see in the
        // Finder gets a line in `--diagnose` that explains itself. Guard the
        // shapes that are easy to regress: raw enum descriptions, empty text.
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }

        try writePackage(in: root, folder: "c1",
                         manifestJSON: v1Manifest(id: "c1", version: 2))
        try writePackage(in: root, folder: "c2", manifestJSON: "{ not json")
        try writePackage(in: root, folder: "c3", manifestJSON: v1Manifest(id: "Bad-Id"))
        try writePackage(in: root, folder: "c4",
                         manifestJSON: v1Manifest(id: "c4"), sheet: (1024, 1024))

        let result = PetLibraryScanner.scan(sources: [petsSource(root)])

        #expect(result.skipped.count == 4)
        for skip in result.skipped {
            #expect(!skip.reason.isEmpty, "\(skip.name) has no reason")
            #expect(!skip.reason.contains("malformedJSON"), "\(skip.name): \(skip.reason)")
            #expect(!skip.reason.contains("PetManifestError"), "\(skip.name): \(skip.reason)")
            #expect(skip.reason.count > 20, "\(skip.name) says too little: \(skip.reason)")
        }
    }
}

@Suite("How a refusal reads")
struct PetPackageErrorMessageTests {

    @Test("a version conflict reads as the conflict, not as a decode failure")
    func versionConflict() {
        let error = PetManifestError.malformedJSON(
            "manifest declares openAICodexV2 but atlas is 1536x1872"
        )
        #expect(error.message == "manifest declares openAICodexV2 but atlas is 1536x1872")
    }

    @Test("every package error has a sentence")
    func everyCaseSpeaks() {
        let cases: [PetPackageError] = [
            .notADirectory("bag"),
            .manifestNotFound("bag"),
            .manifestInvalid("bag", detail: "the manifest has no id"),
            .spritesheetNotFound("sheet.webp"),
            .atlasUnreadable("sheet.webp", detail: "it is not an image"),
        ]
        for error in cases {
            #expect(!error.message.isEmpty, "\(error) says nothing")
            #expect(!error.message.contains("PetPackageError"), "\(error.message)")
        }
    }

    @Test("every image decoding error has a sentence")
    func imageErrorsSpeak() {
        let cases: [ImageDecodingError] = [
            .cannotOpen("a.webp"), .notAnImage("b.webp"),
            .unreadable("c.webp"), .rasterisationFailed("d.webp"),
        ]
        for error in cases {
            #expect(error.message.contains(".webp"), "\(error.message)")
        }
    }
}
