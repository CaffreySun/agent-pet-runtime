import Foundation
import Testing
@testable import AgentPetCore

/// Integration tests against the pet packages that actually exist on this
/// machine at `~/.codex/pets/`.
///
/// These are the tests that matter: a validator that rejects real, shipped
/// pets is not a strict validator, it is a broken one. They no-op when the
/// directory is absent so the suite stays green on other machines.
enum RealPets {
    static var root: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue
        else { return nil }
        return url
    }

    /// Packages that contain a manifest — `x-mega-pet` is an unfinished
    /// hatch-pet run directory and has none.
    static func manifests() -> [(name: String, root: URL)] {
        guard let root else { return [] }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return entries.compactMap { dir in
            let manifest = dir.appendingPathComponent("pet.json")
            guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
            return (dir.lastPathComponent, dir)
        }
    }
}

@Suite("Real packages in ~/.codex/pets", .enabled(if: RealPets.root != nil))
struct RealPackageIntegrationTests {

    @Test("every real package loads and passes validation")
    func allRealPackagesValid() throws {
        let packages = RealPets.manifests()
        try #require(!packages.isEmpty, "expected at least one pet in ~/.codex/pets")

        let loader = PetPackageLoader()
        for (name, root) in packages {
            let loaded = try loader.load(from: root)

            #expect(loaded.isValid,
                    "\(name) failed validation: \(loaded.report.errors.map(\.message))")
            #expect(loaded.definition.id == loaded.definition.manifest.id)
            #expect(loaded.definition.profile.atlasWidth == loaded.atlas?.width)

            // The manifest's own id is authoritative even when it disagrees
            // with the directory name — a folder name may not match the manifest id.
            print("[\(name)] id=\(loaded.definition.id) "
                  + "profile=\(loaded.definition.profile.rawValue) "
                  + "atlas=\(loaded.atlas?.width ?? 0)x\(loaded.atlas?.height ?? 0) "
                  + "warnings=\(loaded.report.warnings.count)")
        }
    }

    @Test("geometry read from the header matches the decoded atlas")
    func headerMatchesPixels() throws {
        for (name, root) in RealPets.manifests() {
            let manifestURL = root.appendingPathComponent("pet.json")
            let manifest = try PetManifest.decode(from: Data(contentsOf: manifestURL))
            let sheet = root.appendingPathComponent(manifest.spritesheetPath)

            let metadata = try AtlasImageDecoder.metadata(at: sheet)
            let decoded = try AtlasImageDecoder.loadRGBA(at: sheet)

            #expect(metadata.width == decoded.width, "\(name) width")
            #expect(metadata.height == decoded.height, "\(name) height")
            #expect(metadata.hasAlpha, "\(name) should have an alpha channel")
            #expect(decoded.hasAlphaChannel, "\(name) should decode with alpha")
        }
    }

    @Test("every real atlas has all its unused cells clean")
    func unusedCellsAreClean() throws {
        let loader = PetPackageLoader()
        for (name, root) in RealPets.manifests() {
            let loaded = try loader.load(from: root)
            let dirty = loaded.report.errors.filter { $0.message.contains("unused column") }
            #expect(dirty.isEmpty, "\(name) has leftovers: \(dirty.map(\.message))")
        }
    }

    @Test("a v2 package is accepted rather than rejected")
    func v2Accepted() throws {
        let loader = PetPackageLoader()
        // No v2 pet is guaranteed to be installed, so this asserts the loader
        // accepts one rather than requiring the machine to have one.
        guard let v2 = RealPets.manifests().first(where: { _, root in
            (try? loader.load(from: root, decodeAtlas: false))?.definition.profile == .openAICodexV2
        }) else { return }

        let loaded = try loader.load(from: v2.root)
        #expect(loaded.definition.profile == .openAICodexV2)
        #expect(loaded.isValid, "a v2 pet must load: \(loaded.report.errors.map(\.message))")
        // V2 is fully supported: its extra rows are gaze poses, not spare
        // capacity, so there is nothing partial left to warn about.
        #expect(loaded.definition.profile.hasLookDirections)
        #expect(loaded.atlas?.height == 2288)
        #expect(loaded.report.warnings.allSatisfy { !$0.message.contains("partially supported") })
    }

    @Test("discovery skips the package that has no manifest")
    func discoverySkipsIncomplete() {
        let names = Set(RealPets.manifests().map(\.name))
        // `x-mega-pet` is a run directory with no pet.json.
        if FileManager.default.fileExists(
            atPath: RealPets.root!.appendingPathComponent("x-mega-pet").path
        ) {
            #expect(!names.contains("x-mega-pet"))
        }
    }
}
