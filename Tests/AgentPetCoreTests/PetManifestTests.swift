import Foundation
import Testing
@testable import AgentPetCore

/// Fixtures are verbatim copies of packages found in `~/.codex/pets/` on the
/// development machine — including the ones that break naive assumptions.
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

    @Test("missing required fields report which one", arguments: [
        (#"{"displayName":"A","spritesheetPath":"s.webp"}"#, "id"),
        (#"{"id":"a","spritesheetPath":"s.webp"}"#,           "displayName"),
        (#"{"id":"a","displayName":"A"}"#,                    "spritesheetPath"),
    ])
    func missingRequiredField(json: String, field: String) {
        #expect(throws: PetManifestError.missingField(field)) {
            try PetManifest.decode(from: Data(json.utf8))
        }
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

    @Test("clippit decodes with its extra ecosystem fields")
    func clippit() throws {
        let m = try PetManifest.decode(from: fixture("clippit"))
        #expect(m.id == "clippit")
        #expect(m.kind == "object")
        #expect(m.source == "codex-pets.net")
        #expect(m.sourceId == "clippit")
        #expect(m.spriteVersionNumber == nil)
        // No explicit version, so the profile must come from the atlas size.
        #expect(m.declaredProfile == nil)
    }

    @Test("clippy decodes from the minimal form")
    func clippy() throws {
        let m = try PetManifest.decode(from: fixture("clippy"))
        #expect(m.id == "clippy")
        #expect(m.kind == nil)
        #expect(m.declaredProfile == nil)
    }

    @Test("ruixing carries a non-ASCII display name intact")
    func ruixing() throws {
        let m = try PetManifest.decode(from: fixture("ruixing"))
        #expect(m.displayName.contains("瑞星"))
        #expect(m.kind == "animal")
    }

    @Test("v2 package declares its profile explicitly")
    func benHillV2() throws {
        let m = try PetManifest.decode(from: fixture("ben-hill-v2"))
        #expect(m.spriteVersionNumber == 2)
        #expect(m.declaredProfile == .openAICodexV2)
        // The manifest id deliberately does not match its directory name
        // (`pet-ben-hill`). The manifest is authoritative.
        #expect(m.id == "real-face-pet")
    }
}

@Suite("Profile resolution")
struct ProfileResolutionTests {

    @Test("v1 atlas with no declared version resolves to V1")
    func v1BySize() throws {
        let m = try PetManifest.decode(from: fixture("clippit"))
        let p = try m.resolveProfile(atlasWidth: 1536, atlasHeight: 1872)
        #expect(p == .openAICodexV1)
    }

    @Test("v2 atlas with matching declared version resolves to V2")
    func v2ByDeclaration() throws {
        let m = try PetManifest.decode(from: fixture("ben-hill-v2"))
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
        let m = try PetManifest.decode(from: fixture("ben-hill-v2"))
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
