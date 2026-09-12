import Foundation

/// The runtime's own pet storage.
///
/// Owns one directory and never writes anywhere else. `~/.codex/pets/` is a
/// read-only source: the Codex toolchain manages it, and a runtime that
/// upgraded or deleted pets in place would eventually corrupt it.
public final class PetStore: @unchecked Sendable {

    public let root: URL
    public var petsDirectory: URL { root.appendingPathComponent("pets") }
    public var stagingDirectory: URL { root.appendingPathComponent("staging") }
    public var backupsDirectory: URL { root.appendingPathComponent("pet-backups") }

    private let loader: PetPackageLoader
    private let fileManager: FileManager

    public init(
        root: URL = BridgeSocketLocation.applicationSupportDirectory,
        loader: PetPackageLoader = PetPackageLoader(),
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.loader = loader
        self.fileManager = fileManager
    }

    // MARK: - Reading

    public func installedPets() -> [InstalledPet] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: petsDirectory, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        return entries.compactMap { directory -> InstalledPet? in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return nil }

            guard let metadata = try? readMetadata(in: directory),
                  let loaded = try? loader.load(from: directory, decodeAtlas: false),
                  loaded.isValid
            else { return nil }

            return InstalledPet(
                metadata: metadata,
                definition: loaded.definition,
                root: directory
            )
        }
        .sorted { $0.metadata.displayName.localizedStandardCompare($1.metadata.displayName) == .orderedAscending }
    }

    public func pet(id: String) -> InstalledPet? {
        installedPets().first { $0.id == id }
    }

    func metadataURL(in directory: URL) -> URL {
        directory
            .appendingPathComponent(PetInstallMetadata.directoryName)
            .appendingPathComponent(PetInstallMetadata.fileName)
    }

    func readMetadata(in directory: URL) throws -> PetInstallMetadata {
        let url = metadataURL(in: directory)
        return try JSONDecoder().decode(PetInstallMetadata.self, from: Data(contentsOf: url))
    }

    // MARK: - Install

    /// Copies a package into runtime storage, validating before it commits.
    ///
    /// The ordering is the safety property: the package is fully copied and
    /// validated in `staging/` first, and `pets/` is not touched until it is
    /// known to be good. A failed install therefore leaves no trace, which is
    /// the "automatic rollback" the design asks for — with nothing to roll back.
    @discardableResult
    public func install(
        from source: URL,
        provenance kind: PetProvenance.Kind,
        now: Date = Date()
    ) throws -> InstalledPet {

        try ensureDirectories()

        let staging = stagingDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fileManager.removeItem(at: staging) }

        do {
            try fileManager.copyItem(at: source, to: staging)
        } catch {
            throw PetStoreError.stagingFailed("could not copy package: \(error)")
        }

        // Validate the copy, not the original: this is what will be installed.
        let loaded: LoadedPetPackage
        do {
            loaded = try loader.load(from: staging)
        } catch {
            throw PetStoreError.stagingFailed("\(error)")
        }
        guard loaded.isValid else {
            throw PetStoreError.validationFailed(
                petID: loaded.definition.id,
                issues: loaded.report.errors.map(\.message)
            )
        }

        let metadata = PetInstallMetadata(
            petID: loaded.definition.id,
            displayName: loaded.definition.displayName,
            compatibilityProfile: loaded.definition.profile.rawValue,
            contentHash: try contentHash(of: staging, manifest: loaded.definition.manifest),
            installedVersion: loaded.definition.manifest.spriteVersionNumber.map(String.init),
            provenance: PetProvenance(
                kind: kind,
                originalSourcePath: source.path,
                installedAt: now,
                managedByRuntime: true
            ),
            lastValidatedAt: now
        )
        try writeMetadata(metadata, in: staging)

        let destination = petsDirectory.appendingPathComponent(loaded.definition.id)
        try commit(staging: staging, to: destination)

        guard let installed = pet(id: metadata.petID) else {
            throw PetStoreError.commitFailed("installed pet could not be read back")
        }
        return installed
    }

    /// Moves staged content into place, displacing whatever was there.
    ///
    /// `rename(2)` cannot replace a non-empty directory, so the existing one is
    /// moved aside first and only deleted once the new one is in place. A
    /// failure at any point puts the original back.
    func commit(staging: URL, to destination: URL) throws {
        let displaced = backupsDirectory.appendingPathComponent(UUID().uuidString)
        var hadPrevious = false

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
            do {
                try fileManager.moveItem(at: destination, to: displaced)
                hadPrevious = true
            } catch {
                throw PetStoreError.commitFailed("could not displace existing package: \(error)")
            }
        }

        do {
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if hadPrevious {
                try? fileManager.moveItem(at: displaced, to: destination)
            }
            throw PetStoreError.commitFailed("\(error)")
        }

        if hadPrevious { try? fileManager.removeItem(at: displaced) }
    }

    // MARK: - Upgrade

    /// Replaces an installed pet from a new package, restoring the old one if
    /// anything goes wrong.
    @discardableResult
    public func upgrade(
        petID: String,
        from source: URL,
        now: Date = Date()
    ) throws -> InstalledPet {

        guard let existing = pet(id: petID) else {
            throw PetStoreError.notInstalled(petID)
        }

        let previousRoot = backupsDirectory.appendingPathComponent("upgrade-\(UUID().uuidString)")
        try fileManager.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)

        do {
            try fileManager.moveItem(at: existing.root, to: previousRoot)
        } catch {
            throw PetStoreError.upgradeFailedAndRestored(petID: petID, detail: "could not snapshot: \(error)")
        }

        do {
            // Reuse the install path, carrying the original provenance forward
            // so an upgrade does not silently make a discovered pet managed.
            let installed = try install(from: source, provenance: existing.metadata.provenance.kind, now: now)
            try? fileManager.removeItem(at: previousRoot)
            return installed
        } catch {
            // Put the previous package back exactly as it was.
            try? fileManager.removeItem(at: existing.root)
            do {
                try fileManager.moveItem(at: previousRoot, to: existing.root)
            } catch {
                throw PetStoreError.upgradeFailedAndRestored(
                    petID: petID,
                    detail: "the previous package could not be restored: \(error)"
                )
            }
            throw PetStoreError.upgradeFailedAndRestored(petID: petID, detail: "\(error)")
        }
    }

    // MARK: - Uninstall

    public struct UninstallOutcome: Sendable, Equatable {
        public let petID: String
        /// False when the pet was not ours to delete.
        public let removedFromDisk: Bool
        public let sourcePreserved: String?
    }

    /// Removes a pet from the runtime.
    ///
    /// A pet the runtime did not install is only deregistered; its files are
    /// left alone. This is the rule that keeps `~/.codex/pets/` intact.
    @discardableResult
    public func uninstall(petID: String) throws -> UninstallOutcome {
        guard let installed = pet(id: petID) else {
            throw PetStoreError.notInstalled(petID)
        }

        guard installed.isManagedByRuntime else {
            return UninstallOutcome(
                petID: petID,
                removedFromDisk: false,
                sourcePreserved: installed.metadata.provenance.originalSourcePath
            )
        }

        do {
            try fileManager.removeItem(at: installed.root)
        } catch {
            throw PetStoreError.commitFailed("could not remove package: \(error)")
        }

        return UninstallOutcome(
            petID: petID,
            removedFromDisk: true,
            sourcePreserved: installed.metadata.provenance.originalSourcePath
        )
    }

    // MARK: - Discovery

    /// Pet packages visible in `~/.codex/pets/`, offered for import.
    ///
    /// Read-only. Nothing here writes to that directory.
    public func discoverCodexPets() -> [(name: String, root: URL, alreadyInstalled: Bool)] {
        let home = fileManager.homeDirectoryForCurrentUser
        let directory = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: $0).appendingPathComponent("pets") }
            ?? home.appendingPathComponent(".codex/pets")

        let installedIDs = Set(installedPets().map(\.id))
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        return entries.compactMap { child in
            guard fileManager.fileExists(atPath: child.appendingPathComponent("pet.json").path),
                  let loaded = try? loader.load(from: child, decodeAtlas: false),
                  loaded.isValid
            else { return nil }
            return (loaded.definition.displayName, child, installedIDs.contains(loaded.definition.id))
        }
        .sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    // MARK: - Helpers

    private func ensureDirectories() throws {
        for directory in [root, petsDirectory, stagingDirectory] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func writeMetadata(_ metadata: PetInstallMetadata, in directory: URL) throws {
        let folder = directory.appendingPathComponent(PetInstallMetadata.directoryName)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(metadata).write(to: metadataURL(in: directory), options: .atomic)
    }

    /// Hashes the package's own files, excluding our metadata directory.
    /// Otherwise the hash would change the moment we recorded it.
    func contentHash(of directory: URL, manifest: PetManifest) throws -> String {
        let sheet = directory.appendingPathComponent(manifest.spritesheetPath)
        let manifestURL = directory.appendingPathComponent(PetPackageLoader.manifestFileName)

        var combined = Data()
        for url in [manifestURL, sheet] {
            combined.append(Data(url.lastPathComponent.utf8))
            combined.append(try Data(contentsOf: url))
        }
        return "sha256:" + Hashing.sha256(combined)
    }
}
