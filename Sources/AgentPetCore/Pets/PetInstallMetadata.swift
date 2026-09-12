import Foundation

/// Where an installed pet came from, and whether the runtime may delete it.
public struct PetProvenance: Codable, Sendable, Equatable {

    public enum Kind: String, Codable, Sendable, Equatable {
        /// Shipped with the app.
        case bundled
        /// Copied in at the user's request from a folder or archive.
        case imported
        /// Discovered in `~/.codex/pets/`, which the Codex toolchain owns.
        case codexPets
        /// Already in the runtime's own storage.
        case local
    }

    public let kind: Kind
    /// Where the user's own copy lives. Never written to.
    public let originalSourcePath: String?
    public let installedAt: Date
    /// The single field that decides whether uninstall may touch the disk.
    ///
    /// Everything else in this record is informational. Without this the rule
    /// "never delete the user's original package" is unimplementable, because
    /// nothing distinguishes a copy we made from a directory we merely point at.
    public let managedByRuntime: Bool

    public init(
        kind: Kind,
        originalSourcePath: String?,
        installedAt: Date,
        managedByRuntime: Bool
    ) {
        self.kind = kind
        self.originalSourcePath = originalSourcePath
        self.installedAt = installedAt
        self.managedByRuntime = managedByRuntime
    }
}

/// The runtime's private bookkeeping for an installed pet.
///
/// Stored under `.agentpet/` inside the package rather than beside the
/// manifest, so the validator's payload rules never see it as an unexpected
/// file in the user's content.
public struct PetInstallMetadata: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public static let directoryName = ".agentpet"
    public static let fileName = "metadata.json"

    public var schemaVersion: Int
    public var petID: String
    public var displayName: String
    public var compatibilityProfile: String
    public var contentHash: String
    /// From the manifest, when it declares one. Absent for most packages.
    public var installedVersion: String?
    public var provenance: PetProvenance
    public var lastValidatedAt: Date?

    public init(
        petID: String,
        displayName: String,
        compatibilityProfile: String,
        contentHash: String,
        installedVersion: String? = nil,
        provenance: PetProvenance,
        lastValidatedAt: Date? = nil,
        schemaVersion: Int = PetInstallMetadata.currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.petID = petID
        self.displayName = displayName
        self.compatibilityProfile = compatibilityProfile
        self.contentHash = contentHash
        self.installedVersion = installedVersion
        self.provenance = provenance
        self.lastValidatedAt = lastValidatedAt
    }
}

/// An installed pet as the manager sees it.
public struct InstalledPet: Sendable, Equatable, Identifiable {
    public let metadata: PetInstallMetadata
    public let definition: PetDefinition
    public let root: URL

    public var id: String { metadata.petID }
    public var isManagedByRuntime: Bool { metadata.provenance.managedByRuntime }
}

public enum PetStoreError: Error, Equatable, Sendable {
    case notInstalled(String)
    /// The package failed validation; nothing was written.
    case validationFailed(petID: String, issues: [String])
    case notManagedByRuntime(String)
    case stagingFailed(String)
    case commitFailed(String)
    case upgradeFailedAndRestored(petID: String, detail: String)
}
