import Foundation
import Testing
@testable import AgentPetCore

/// Fixtures are synthetic, but each reproduces a shape real packages actually
/// have: a minimal manifest, one carrying extra third-party fields, a V2
/// package whose id differs from its folder name, and a non-ASCII display
/// name. They are synthetic so the repository carries no third-party or
/// personal content.
private func fixture(_ name: String) throws -> Data {
    let url = Bundle.module.url(
        forResource: "Fixtures/manifests/\(name)",
        withExtension: "json"
    )
    guard let url else {
        Issue.record("missing fixture \(name).json")
        throw PetManifestError.malformedJSON("fixture not found")
    }
    return try Data(contentsOf: url)
}

@Suite("PetManifest decoding")
struct PetManifestTests {

    @Test("minimal manifest decodes")
    func minimalManifest() throws {
        let json = #"""
        {"id":"clippy","displayName":"Clippy","description":"d","spritesheetPath":"spritesheet.webp"}
        """#
        let m = try PetManifest.decode(from: Data(json.utf8))
        #expect(m.id == "clippy")
        #expect(m.displayName == "Clippy")
        #expect(m.spritesheetPath == "spritesheet.webp")
        #expect(m.spriteVersionNumber == nil)
    }

    @Test("missing description falls back to displayName rather than failing")
    func descriptionFallback() throws {
        let json = #"{"id":"a","displayName":"Alpha","spritesheetPath":"s.webp"}"#
        let m = try PetManifest.decode(from: Data(json.utf8))
        #expect(m.description == "Alpha")
    }

    @Test("unknown fields are ignored, not rejected")
    func unknownFieldsIgnored() throws {
        let json = #"""
        {"id":"a","displayName":"A","spritesheetPath":"s.webp",
         "futureField":{"nested":[1,2]},"anotherOne":true}
        """#
        let m = try PetManifest.decode(from: Data(json.utf8))
        #expect(m.id == "a")
    }

    @Test("a manifest with no id at all reports that")
    func missingID() {
        #expect(throws: PetManifestError.missingField("id")) {
            try PetManifest.decode(from: Data(#"{"displayName":"A","spritesheetPath":"s.webp"}"#.utf8))
        }
    }

    @Test("the folder name is the id of last resort, as it is in Codex")
    func idFallsBackToFolderName() throws {
        // Legacy avatar.json files are written this way.
        let json = #"{"displayName":"Legacy","spritesheetPath":"spritesheet.webp"}"#
        let manifest = try PetManifest.decode(from: Data(json.utf8), fallbackID: "old-friend")

        #expect(manifest.id == "old-friend")
        // An explicit id still wins over the folder it sits in.
        let named = try PetManifest.decode(
            from: Data(#"{"id":"explicit","displayName":"N"}"#.utf8), fallbackID: "folder"
        )
        #expect(named.id == "explicit")
    }

    @Test("a folder name that is not a valid id is rejected, not renamed")
    func invalidFallbackID() {
        #expect(throws: PetManifestError.invalidID("Clippy")) {
            try PetManifest.decode(
                from: Data(#"{"displayName":"A","spritesheetPath":"s.webp"}"#.utf8),
                fallbackID: "Clippy"
            )
        }
    }

    @Test("missing displayName falls back to the id; missing spritesheetPath to the convention")
    func optionalFieldsFallBack() throws {
        let manifest = try PetManifest.decode(from: Data(#"{"id":"a"}"#.utf8))
        #expect(manifest.displayName == "a")
        #expect(manifest.spritesheetPath == "spritesheet.webp")
        #expect(manifest.description == "a")
    }

    @Test("invalid ids are rejected", arguments: [
        "", "Clippy", "-leading", ".dotted", "has space", "UPPER", "emoji🐱",
    ])
    func invalidID(id: String) {
        let json = #"{"id":"\#(id)","displayName":"A","spritesheetPath":"s.webp"}"#
        #expect(throws: PetManifestError.self) {
            try PetManifest.decode(from: Data(json.utf8))
        }
    }

    @Test("id longer than 64 characters is rejected")
    func overlyLongID() {
        let id = String(repeating: "a", count: 65)
        let json = #"{"id":"\#(id)","displayName":"A","spritesheetPath":"s.webp"}"#
        #expect(throws: PetManifestError.invalidID(id)) {
            try PetManifest.decode(from: Data(json.utf8))
        }
    }

    @Test("blank spritesheetPath is rejected")
    func blankPath() {
        let json = #"{"id":"a","displayName":"A","spritesheetPath":"   "}"#
        #expect(throws: PetManifestError.emptySpritesheetPath) {
            try PetManifest.decode(from: Data(json.utf8))
        }
    }

    @Test("malformed JSON reports a parse failure, not a missing field")
    func malformedJSON() {
        #expect(throws: PetManifestError.self) {
            try PetManifest.decode(from: Data("{not json".utf8))
        }
    }
}

@Suite("PetManifest against real packages from ~/.codex/pets")
struct RealPackageManifestTests {

    @Test("a manifest with extra ecosystem fields decodes")
    func ecosystemFields() throws {
        let m = try PetManifest.decode(from: fixture("ecosystem"))
        #expect(m.id == "pebble")
        #expect(m.kind == "object")
        #expect(m.source == "example-pets.test")
        #expect(m.sourceId == "pebble")
        #expect(m.spriteVersionNumber == nil)
        // No explicit version, so the profile must come from the atlas size.
        #expect(m.declaredProfile == nil)
    }

    @Test("the minimal form decodes")
    func minimalForm() throws {
        let m = try PetManifest.decode(from: fixture("minimal"))
        #expect(m.id == "comet")
        #expect(m.kind == nil)
        #expect(m.declaredProfile == nil)
    }

    @Test("a non-ASCII display name survives intact")
    func unicodeDisplayName() throws {
        let m = try PetManifest.decode(from: fixture("unicode"))
        #expect(m.displayName.contains("月亮兔"))
        #expect(m.kind == "animal")
    }

    @Test("a v2 package declares its profile explicitly")
    func v2Declaration() throws {
        let m = try PetManifest.decode(from: fixture("v2"))
        #expect(m.spriteVersionNumber == 2)
        #expect(m.declaredProfile == .openAICodexV2)
        // The id deliberately does not match the file it sits in, as happens
        // with real packages whose folder name differs from the manifest's.
        #expect(m.id == "lantern-moth")
    }
}

@Suite("Profile resolution")
struct ProfileResolutionTests {

    @Test("v1 atlas with no declared version resolves to V1")
    func v1BySize() throws {
        let m = try PetManifest.decode(from: fixture("ecosystem"))
        let p = try m.resolveProfile(atlasWidth: 1536, atlasHeight: 1872)
        #expect(p == .openAICodexV1)
    }

    @Test("v2 atlas with matching declared version resolves to V2")
    func v2ByDeclaration() throws {
        let m = try PetManifest.decode(from: fixture("v2"))
        let p = try m.resolveProfile(atlasWidth: 1536, atlasHeight: 2288)
        #expect(p == .openAICodexV2)
    }

    @Test("v2 atlas without a declared version still resolves to V2")
    func v2BySize() throws {
        let json = #"{"id":"a","displayName":"A","spritesheetPath":"s.webp"}"#
        let m = try PetManifest.decode(from: Data(json.utf8))
        #expect(try m.resolveProfile(atlasWidth: 1536, atlasHeight: 2288) == .openAICodexV2)
    }

    @Test("a declared version contradicting the atlas is a defect, not a guess")
    func contradictionRejected() throws {
        let m = try PetManifest.decode(from: fixture("v2"))
        #expect(throws: PetManifestError.self) {
            try m.resolveProfile(atlasWidth: 1536, atlasHeight: 1872)
        }
    }

    @Test("an atlas matching no profile is rejected")
    func unknownGeometry() throws {
        let json = #"{"id":"a","displayName":"A","spritesheetPath":"s.webp"}"#
        let m = try PetManifest.decode(from: Data(json.utf8))
        #expect(throws: PetManifestError.self) {
            try m.resolveProfile(atlasWidth: 1024, atlasHeight: 1024)
        }
    }
}
