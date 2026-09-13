import Foundation

public enum PetManifestError: Error, Equatable, Sendable {
    case malformedJSON(String)
    case missingField(String)
    case invalidID(String)
    case emptySpritesheetPath
}

/// The `pet.json` shipped inside a pet package.
///
/// Decoding is deliberately lenient, and now matches Codex's own loader
/// (`codex-rs/tui/src/pets/model.rs`): third-party tooling (`codex-pets.net`
/// and friends) already emits `kind`, `source`, `sourceId`,
/// `spriteVersionNumber` and no doubt more, so unknown keys are ignored;
/// `displayName` falls back to the id, and `spritesheetPath` to the
/// conventional file name. Only the id has to come from somewhere — the
/// manifest, or the folder the package sits in, which is how legacy
/// `avatar.json` files are written.
public struct PetManifest: Sendable, Hashable {
    public let id: String
    public let displayName: String
    public let description: String?
    public let spritesheetPath: String

    // Observed in the wild; all optional.
    public let spriteVersionNumber: Int?
    public let kind: String?
    public let source: String?
    public let sourceId: String?

    public init(
        id: String,
        displayName: String,
        description: String? = nil,
        spritesheetPath: String,
        spriteVersionNumber: Int? = nil,
        kind: String? = nil,
        source: String? = nil,
        sourceId: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.spritesheetPath = spritesheetPath
        self.spriteVersionNumber = spriteVersionNumber
        self.kind = kind
        self.source = source
        self.sourceId = sourceId
    }

    /// What Codex assumes when a manifest does not name its spritesheet.
    public static let defaultSpritesheetPath = "spritesheet.webp"

    /// Every field is optional on disk; the required ones are enforced here so
    /// the fallbacks live in one place rather than in each caller.
    private struct RawManifest: Decodable {
        let id: String?
        let displayName: String?
        let description: String?
        let spritesheetPath: String?
        let spriteVersionNumber: Int?
        let kind: String?
        let source: String?
        let sourceId: String?
    }

    /// - Parameter fallbackID: the package folder's name, used when the
    ///   manifest has no `id`. Codex does the same; legacy `avatar.json` files
    ///   rely on it. The result still has to be a valid id, so a folder named
    ///   `Clippy` without an explicit id is rejected rather than silently
    ///   renamed — every id this runtime stores is one it can write to a
    ///   config file and match again later.
    public static func decode(from data: Data, fallbackID: String? = nil) throws -> PetManifest {
        let raw: RawManifest
        do {
            raw = try JSONDecoder().decode(RawManifest.self, from: data)
        } catch let error as DecodingError {
            throw PetManifestError.malformedJSON(Self.describe(error))
        } catch {
            throw PetManifestError.malformedJSON(String(describing: error))
        }

        let declaredID = raw.id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let id = declaredID.isEmpty ? fallbackID : declaredID else {
            throw PetManifestError.missingField("id")
        }
        guard Self.isValidID(id) else {
            throw PetManifestError.invalidID(id)
        }

        let declaredName = raw.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = declaredName.isEmpty ? id : declaredName

        let path = raw.spritesheetPath?.trimmingCharacters(in: .whitespaces)
            ?? Self.defaultSpritesheetPath
        guard !path.isEmpty else {
            throw PetManifestError.emptySpritesheetPath
        }

        return PetManifest(
            id: id,
            displayName: displayName,
            // A manifest without a description is legal; fall back to the name
            // so the UI never has to special-case an empty string.
            description: raw.description ?? displayName,
            spritesheetPath: path,
            spriteVersionNumber: raw.spriteVersionNumber,
            kind: raw.kind,
            source: raw.source,
            sourceId: raw.sourceId
        )
    }

    /// Profile implied by the manifest alone. `nil` means "decide from the
    /// atlas dimensions instead" — see `resolveProfile(atlasWidth:atlasHeight:)`.
    public var declaredProfile: CompatibilityProfile? {
        switch spriteVersionNumber {
        case 2:  return .openAICodexV2
        case 1:  return .openAICodexV1
        default: return nil
        }
    }

    /// Resolve the profile using the manifest's explicit version first, and the
    /// measured atlas size as the fallback. A declared version that contradicts
    /// the actual dimensions is a package defect, not something to paper over.
    public func resolveProfile(atlasWidth: Int, atlasHeight: Int) throws -> CompatibilityProfile {
        let measured = CompatibilityProfile.matching(width: atlasWidth, height: atlasHeight)
        guard let measured else {
            throw PetManifestError.malformedJSON(
                "atlas is \(atlasWidth)x\(atlasHeight); no compatibility profile matches"
            )
        }
        if let declared = declaredProfile, declared != measured {
            throw PetManifestError.malformedJSON(
                "manifest declares \(declared.rawValue) but atlas is \(atlasWidth)x\(atlasHeight)"
            )
        }
        return measured
    }

    static func isValidID(_ id: String) -> Bool {
        guard let first = id.first, first.isASCII, first.isLowercase || first.isNumber else {
            return false
        }
        guard id.count <= 64 else { return false }
        return id.allSatisfy { ch in
            ch.isASCII && (ch.isLowercase || ch.isNumber || ch == "." || ch == "_" || ch == "-")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let ctx):        return "data corrupted: \(ctx.debugDescription)"
        case .keyNotFound(let key, _):       return "missing field: \(key.stringValue)"
        case .typeMismatch(let type, let ctx): return "type mismatch for \(type): \(ctx.debugDescription)"
        case .valueNotFound(let type, _):    return "null value for \(type)"
        @unknown default:                    return String(describing: error)
        }
    }
}
