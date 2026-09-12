import Foundation

public enum PetManifestError: Error, Equatable, Sendable {
    case malformedJSON(String)
    case missingField(String)
    case invalidID(String)
    case emptySpritesheetPath
}

/// The `pet.json` shipped inside a pet package.
///
/// Decoding is deliberately lenient: third-party tooling (`codex-pets.net` and
/// friends) already emits `kind`, `source`, `sourceId`, `spriteVersionNumber`
/// and no doubt more. Unknown keys are ignored rather than rejected, and only
/// `id` / `displayName` / `spritesheetPath` are actually required.
public struct PetManifest: Codable, Sendable, Equatable {
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

    private enum CodingKeys: String, CodingKey {
        case id, displayName, description, spritesheetPath
        case spriteVersionNumber, kind, source, sourceId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        guard let id = try c.decodeIfPresent(String.self, forKey: .id) else {
            throw PetManifestError.missingField("id")
        }
        guard let displayName = try c.decodeIfPresent(String.self, forKey: .displayName) else {
            throw PetManifestError.missingField("displayName")
        }
        guard let path = try c.decodeIfPresent(String.self, forKey: .spritesheetPath) else {
            throw PetManifestError.missingField("spritesheetPath")
        }

        guard Self.isValidID(id) else {
            throw PetManifestError.invalidID(id)
        }
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PetManifestError.emptySpritesheetPath
        }

        self.id = id
        self.displayName = displayName
        // A manifest without a description is legal; fall back to the name so
        // the UI never has to special-case an empty string.
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? displayName
        self.spritesheetPath = path
        self.spriteVersionNumber = try c.decodeIfPresent(Int.self, forKey: .spriteVersionNumber)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind)
        self.source = try c.decodeIfPresent(String.self, forKey: .source)
        self.sourceId = try c.decodeIfPresent(String.self, forKey: .sourceId)
    }

    public static func decode(from data: Data) throws -> PetManifest {
        do {
            return try JSONDecoder().decode(PetManifest.self, from: data)
        } catch let error as PetManifestError {
            throw error
        } catch let error as DecodingError {
            throw PetManifestError.malformedJSON(Self.describe(error))
        } catch {
            throw PetManifestError.malformedJSON(String(describing: error))
        }
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
