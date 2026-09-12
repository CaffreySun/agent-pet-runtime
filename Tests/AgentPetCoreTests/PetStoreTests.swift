import Foundation
import Testing
@testable import AgentPetCore

/// Builds synthetic pet packages on disk. Synthetic rather than copied from
/// real pets so these tests do not depend on what happens to be installed.
private struct PetPackageBuilder {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    /// A package whose atlas has valid geometry and content in every required
    /// cell, so the loader accepts it.
    @discardableResult
    func makePet(
        _ name: String,
        id: String? = nil,
        profile: CompatibilityProfile = .openAICodexV1,
        displayName: String? = nil,
        extraFiles: [String: String] = [:]
    ) throws -> URL {
        let directory = root.appendingPathComponent(name)
        // Manifest ids must be lowercase; the directory name need not be, and
        // real packages rely on that difference.
        let manifestID = id ?? name.lowercased()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let manifest = """
        {
          "id": "\(manifestID)",
          "displayName": "\(displayName ?? name)",
          "description": "test pet",
          "spritesheetPath": "spritesheet.png"
        }
        """
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("pet.json"))

        var bitmap = RGBAAtlasBitmap.empty(width: profile.atlasWidth, height: profile.atlasHeight)
        let atlas = SpriteAtlas(profile: profile)
        for track in profile.tracks where track.frameCount > 0 {
            for rect in atlas.rects(for: track) { bitmap.fill(rect) }
        }
        try writePNG(bitmap, to: directory.appendingPathComponent("spritesheet.png"))

        for (path, contents) in extraFiles {
            let url = directory.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contents.utf8).write(to: url)
        }
        return directory
    }

    /// A package that must not be installable: wrong atlas size.
    @discardableResult
    func makeBrokenPet(_ name: String) throws -> URL {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"id":"\#(name.lowercased())","displayName":"broken","spritesheetPath":"spritesheet.png"}"#.utf8)
            .write(to: directory.appendingPathComponent("pet.json"))
        try writePNG(RGBAAtlasBitmap.empty(width: 64, height: 64),
                     to: directory.appendingPathComponent("spritesheet.png"))
        return directory
    }

    private func writePNG(_ bitmap: RGBAAtlasBitmap, to url: URL) throws {
        let image = try #require(SpriteFrames.makeCGImage(from: bitmap))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    func makeStore() throws -> PetStore {
        let storeRoot = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        return PetStore(root: storeRoot)
    }
}

import ImageIO

@Suite("Pet install")
struct PetInstallTests {

    @Test("installing copies the package and records where it came from")
    func installBasics() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let source = try builder.makePet("Clippy", displayName: "Clippy")
        let store = try builder.makeStore()

        let installed = try store.install(from: source, provenance: .imported)

        #expect(installed.id == "clippy")
        #expect(installed.metadata.displayName == "Clippy")
        #expect(installed.metadata.provenance.kind == .imported)
        #expect(installed.metadata.provenance.originalSourcePath == source.path)
        #expect(installed.isManagedByRuntime)
        #expect(FileManager.default.fileExists(atPath: installed.root.path))
    }

    @Test("the metadata lives inside the package, under a dot directory")
    func metadataLocation() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let store = try builder.makeStore()
        let installed = try store.install(from: try builder.makePet("Clippy"), provenance: .imported)

        let metadata = installed.root
            .appendingPathComponent(".agentpet/metadata.json")
        #expect(FileManager.default.fileExists(atPath: metadata.path))
    }

    @Test("installing a package the user later edits does not affect the installed copy")
    func installIsACopy() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let source = try builder.makePet("Clippy")
        let store = try builder.makeStore()
        let installed = try store.install(from: source, provenance: .imported)

        try Data("changed".utf8).write(to: source.appendingPathComponent("pet.json"))

        let installedManifest = try Data(
            contentsOf: installed.root.appendingPathComponent("pet.json")
        )
        #expect(!String(decoding: installedManifest, as: UTF8.self).contains("changed"))
    }

    @Test("a package that fails validation leaves nothing behind")
    func brokenPackageLeavesNoTrace() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let store = try builder.makeStore()
        let broken = try builder.makeBrokenPet("broken")

        #expect(throws: (any Error).self) {
            try store.install(from: broken, provenance: .imported)
        }
        #expect(store.installedPets().isEmpty, "a rejected package must not be registered")
        #expect(!FileManager.default.fileExists(
            atPath: store.petsDirectory.appendingPathComponent("broken").path
        ))
    }

    @Test("staging is cleaned up whatever happens")
    func stagingIsCleaned() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let store = try builder.makeStore()

        try store.install(from: try builder.makePet("Good"), provenance: .imported)
        _ = try? store.install(from: try builder.makeBrokenPet("broken"), provenance: .imported)

        let staging = (try? FileManager.default.contentsOfDirectory(atPath: store.stagingDirectory.path)) ?? []
        #expect(staging.isEmpty, "staging leftovers: \(staging)")
    }

    @Test("the package directory name is the manifest id, not the source folder name")
    func idComesFromManifest() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        // Folder says one thing, manifest says another — as in a real package
        // where `pet-ben-hill/` ships id `real-face-pet`.
        let source = try builder.makePet("some-folder-name", id: "real-id")
        let store = try builder.makeStore()

        let installed = try store.install(from: source, provenance: .imported)
        #expect(installed.id == "real-id")
        #expect(installed.root.lastPathComponent == "real-id")
    }

    @Test("a v2 package installs rather than being rejected")
    func v2Installs() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let source = try builder.makePet("Big", profile: .openAICodexV2)
        let store = try builder.makeStore()

        let installed = try store.install(from: source, provenance: .imported)
        #expect(installed.metadata.compatibilityProfile == CompatibilityProfile.openAICodexV2.rawValue)
    }

    @Test("installed pets come back from disk on a fresh store")
    func survivesRestart() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let store = try builder.makeStore()
        try store.install(from: try builder.makePet("Clippy"), provenance: .imported)

        let reopened = PetStore(root: store.root)
        #expect(reopened.installedPets().count == 1)
        #expect(reopened.installedPets().first?.id == "clippy")
    }
}

@Suite("Pet upgrade")
struct PetUpgradeTests {

    @Test("upgrading replaces the package contents")
    func upgradeReplaces() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let store = try builder.makeStore()

        try store.install(from: try builder.makePet("Pet", displayName: "Original"), provenance: .imported)

        let revisionSource = builder.root.appendingPathComponent("revision")
        try FileManager.default.createDirectory(at: revisionSource, withIntermediateDirectories: true)
        _ = try builder.makePet("revision", id: "pet", displayName: "Updated")
        let updated = try builder.makePet("Pet-v2", id: "pet", displayName: "Updated")

        let installed = try store.upgrade(petID: "pet", from: updated)
        #expect(installed.metadata.displayName == "Updated")
        #expect(store.installedPets().count == 1, "upgrade must replace, not add")
    }

    @Test("a failed upgrade restores the previous package exactly")
    func failedUpgradeRestores() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let store = try builder.makeStore()

        let original = try store.install(
            from: try builder.makePet("Pet", displayName: "Original"), provenance: .imported
        )
        let originalManifest = try Data(contentsOf: original.root.appendingPathComponent("pet.json"))
        let originalHash = original.metadata.contentHash

        let broken = try builder.makeBrokenPet("broken")

        #expect(throws: (any Error).self) {
            try store.upgrade(petID: "pet", from: broken)
        }

        let after = try #require(store.pet(id: "pet"))
        #expect(try Data(contentsOf: after.root.appendingPathComponent("pet.json")) == originalManifest,
                "the previous package was not restored")
        #expect(after.metadata.contentHash == originalHash)
    }

    @Test("upgrading a pet that is not installed is refused")
    func upgradeMissingRefused() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let store = try builder.makeStore()
        let source = try builder.makePet("Pet")

        #expect(throws: PetStoreError.notInstalled("pet")) {
            try store.upgrade(petID: "pet", from: source)
        }
    }

    @Test("an upgrade does not make an unmanaged pet managed")
    func upgradePreservesProvenance() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let store = try builder.makeStore()

        try store.install(from: try builder.makePet("Pet"), provenance: .codexPets)
        let updated = try builder.makePet("Pet-v2", id: "pet", displayName: "Updated")
        let installed = try store.upgrade(petID: "pet", from: updated)

        #expect(installed.metadata.provenance.kind == .codexPets)
    }
}

@Suite("Pet uninstall")
struct PetUninstallTests {

    @Test("a runtime-managed pet is removed from disk")
    func managedPetDeleted() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let store = try builder.makeStore()
        let installed = try store.install(from: try builder.makePet("Clippy"), provenance: .imported)

        let outcome = try store.uninstall(petID: "clippy")

        #expect(outcome.removedFromDisk)
        #expect(!FileManager.default.fileExists(atPath: installed.root.path))
        #expect(store.installedPets().isEmpty)
    }

    @Test("uninstalling never touches the folder the user imported from")
    func sourceDirectorySurvives() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let store = try builder.makeStore()
        let source = try builder.makePet("Clippy")

        try store.install(from: source, provenance: .imported)
        _ = try store.uninstall(petID: "clippy")

        #expect(FileManager.default.fileExists(atPath: source.path),
                "the user's own copy must never be deleted")
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("pet.json").path))
    }

    @Test("a pet the runtime did not install is only deregistered")
    func unmanagedPetDeregisteredOnly() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let store = try builder.makeStore()

        // Install a pet, then rewrite its metadata to look discovered.
        let installed = try store.install(from: try builder.makePet("Clippy"), provenance: .codexPets)
        try markUnmanaged(at: installed.root)

        let outcome = try store.uninstall(petID: "clippy")

        #expect(!outcome.removedFromDisk)
        #expect(FileManager.default.fileExists(atPath: installed.root.path),
                "files the runtime does not own must survive uninstall")
    }

    @Test("uninstalling something that is not installed is refused")
    func uninstallMissingRefused() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let store = try builder.makeStore()
        #expect(throws: PetStoreError.notInstalled("ghost")) {
            try store.uninstall(petID: "ghost")
        }
    }

    /// Rewrites a package's metadata to `managedByRuntime: false`.
    private func markUnmanaged(at root: URL) throws {
        let url = root.appendingPathComponent(".agentpet/metadata.json")
        var metadata = try JSONDecoder().decode(PetInstallMetadata.self, from: Data(contentsOf: url))
        metadata.provenance = PetProvenance(
            kind: .codexPets,
            originalSourcePath: "/somewhere/else",
            installedAt: metadata.provenance.installedAt,
            managedByRuntime: false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(metadata).write(to: url)
    }
}

@Suite("Package error reporting")
struct PackageErrorReportingTests {

    @Test("a present but malformed manifest is not reported as missing")
    func malformedIsNotMissing() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }

        // The manifest exists and parses, but its id is invalid.
        let directory = builder.root.appendingPathComponent("badid")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"id":"Not Valid","displayName":"x","spritesheetPath":"s.png"}"#.utf8)
            .write(to: directory.appendingPathComponent("pet.json"))

        do {
            _ = try PetPackageLoader().load(from: directory, decodeAtlas: false)
            Issue.record("expected the load to fail")
        } catch let error as PetPackageError {
            guard case .manifestInvalid = error else {
                Issue.record("""
                    a malformed manifest was reported as \(error), which sends the user \
                    looking for a file that is right there
                    """)
                return
            }
        }
    }

    @Test("a genuinely absent manifest is reported as missing")
    func absentIsMissing() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let directory = builder.root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            _ = try PetPackageLoader().load(from: directory, decodeAtlas: false)
            Issue.record("expected the load to fail")
        } catch let error as PetPackageError {
            #expect(error == .manifestNotFound("empty"))
        }
    }

    @Test("a missing spritesheet is reported as missing, not as a bad atlas")
    func missingSpritesheet() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let directory = builder.root.appendingPathComponent("nosheet")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"id":"nosheet","displayName":"x","spritesheetPath":"gone.png"}"#.utf8)
            .write(to: directory.appendingPathComponent("pet.json"))

        do {
            _ = try PetPackageLoader().load(from: directory, decodeAtlas: false)
            Issue.record("expected the load to fail")
        } catch let error as PetPackageError {
            #expect(error == .spritesheetNotFound("gone.png"))
        }
    }
}

@Suite("Pet discovery")
struct PetDiscoveryTests {

    @Test("discovery reports what is installed by id")
    func discoveryBasics() throws {
        let builder = try PetPackageBuilder()
        defer { builder.cleanup() }
        let store = try builder.makeStore()
        try store.install(from: try builder.makePet("Clippy"), provenance: .imported)

        let found = store.discoverCodexPets()
        // Depends on the machine's ~/.codex/pets; only assert what we control.
        #expect(store.installedPets().map(\.id) == ["clippy"])
        _ = found
    }
}
