import Foundation

/// A pet package that has been parsed and validated enough to name.
public struct PetDefinition: Sendable, Hashable {
    public let manifest: PetManifest
    public let profile: CompatibilityProfile
    public let root: URL
    public let spritesheetURL: URL

    public var id: String { manifest.id }
    public var displayName: String { manifest.displayName }
    public var description: String { manifest.description ?? manifest.displayName }
}

public struct LoadedPetPackage: Sendable {
    public let definition: PetDefinition
    public let atlas: RGBAAtlasBitmap?
    public let report: ValidationReport

    public var isValid: Bool { report.isValid }
}

public enum PetPackageError: Error, Equatable, Sendable {
    case notADirectory(String)
    case manifestNotFound(String)
    /// The manifest is present but unusable. Distinct from `manifestNotFound`
    /// so a malformed id is not reported as a missing file.
    case manifestInvalid(String, detail: String)
    case spritesheetNotFound(String)
    /// The spritesheet exists but cannot be used. `detail` says why — without
    /// it the one reason a package states for itself is thrown away here, and
    /// the most common way to be refused (a `spriteVersionNumber` that
    /// contradicts the sheet's size) becomes indistinguishable from a corrupt
    /// file.
    case atlasUnreadable(String, detail: String)

    /// What to say about a package that will not load, for the user who can
    /// see its folder and not the error.
    public var message: String {
        switch self {
        case .notADirectory(let name):
            return "“\(name)” is not a directory"
        case .manifestNotFound(let name):
            return "“\(name)” has no manifest this runtime reads"
        case .manifestInvalid(_, let detail):
            return detail
        case .spritesheetNotFound(let path):
            return "the spritesheet “\(path)” is missing, or resolves outside the package"
        case .atlasUnreadable(let path, let detail):
            return "the atlas “\(path)” cannot be used: \(detail)"
        }
    }
}

/// Reads a pet package from a directory.
///
/// Validation is staged cheapest-first, and each stage short-circuits: a
/// package with a broken manifest never has its image decoded, and an atlas of
/// the wrong size is never rasterised into memory.
public struct PetPackageLoader: Sendable {
    public var pathValidator: PathSafetyValidator
    public var payloadValidator: PayloadValidator
    public var atlasValidator: AtlasValidator

    public init(
        pathValidator: PathSafetyValidator = PathSafetyValidator(),
        payloadValidator: PayloadValidator = PayloadValidator(),
        atlasValidator: AtlasValidator = AtlasValidator()
    ) {
        self.pathValidator = pathValidator
        self.payloadValidator = payloadValidator
        self.atlasValidator = atlasValidator
    }

    /// The reason a stage failed, in words.
    ///
    /// Our own errors carry a sentence; anything else (a decoding error from
    /// Foundation, say) falls back to its description. One place to add the
    /// next error type, and one place to keep `--diagnose` from printing an
    /// enum case at a user.
    static func detail(of error: Error) -> String {
        switch error {
        case let error as PetManifestError:  return error.message
        case let error as ImageDecodingError: return error.message
        default:                             return "\(error)"
        }
    }

    public static let manifestFileName = "pet.json"
    /// Codex reads a second, older directory whose packages are named this way.
    public static let legacyManifestFileName = "avatar.json"

    /// The manifest a package uses, given the name it is expected to have.
    ///
    /// Codex accepts either file name, preferring `pet.json`, and so does
    /// this: the caller that knows which directory a package came from passes
    /// the name, and a caller holding only a path lets the file decide.
    static func manifestURL(in root: URL, named preferred: String?) throws -> URL {
        if let preferred {
            let url = root.appendingPathComponent(preferred)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PetPackageError.manifestNotFound(root.lastPathComponent)
            }
            return url
        }
        for name in [manifestFileName, legacyManifestFileName] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        throw PetPackageError.manifestNotFound(root.lastPathComponent)
    }

    /// Parse and validate a package. `decodeAtlas` skips the expensive pixel
    /// stage — useful for listing a library without rasterising every pet.
    ///
    /// `manifestFileName` names the manifest to require; passing nil takes the
    /// first of `pet.json` / `avatar.json` that exists, which is what Codex
    /// does when it is handed a path rather than a pet id.
    public func load(
        from root: URL,
        decodeAtlas: Bool = true,
        manifestFileName: String? = nil
    ) throws -> LoadedPetPackage {
        var report = ValidationReport()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw PetPackageError.notADirectory(root.lastPathComponent)
        }

        // 1. Payload — rejects executables before anything is parsed.
        report.merge(payloadValidator.validate(packageRoot: root))

        // 2. Manifest.
        let manifestURL = try Self.manifestURL(in: root, named: manifestFileName)

        let manifest: PetManifest
        do {
            // The folder name is the id of last resort, as it is in Codex.
            manifest = try PetManifest.decode(
                from: Data(contentsOf: manifestURL),
                fallbackID: root.lastPathComponent
            )
        } catch {
            let why = Self.detail(of: error)
            report.add("manifest", .error, why)
            // Nothing downstream can run without an id and a sprite path.
            throw PetPackageError.manifestInvalid(root.lastPathComponent, detail: why)
        }

        // 3. Path safety for the declared spritesheet.
        let spritesheetURL: URL
        do {
            spritesheetURL = try pathValidator.resolve(manifest.spritesheetPath, within: root)
        } catch {
            report.add("path", .error, "spritesheetPath '\(manifest.spritesheetPath)': \(error)")
            throw PetPackageError.spritesheetNotFound(manifest.spritesheetPath)
        }

        guard FileManager.default.fileExists(atPath: spritesheetURL.path) else {
            report.add("path", .error, "spritesheet '\(manifest.spritesheetPath)' does not exist")
            throw PetPackageError.spritesheetNotFound(manifest.spritesheetPath)
        }

        // 4. Geometry, from the file header only.
        let metadata: AtlasImageMetadata
        do {
            metadata = try AtlasImageDecoder.metadata(at: spritesheetURL)
        } catch {
            let why = Self.detail(of: error)
            report.add("atlas", .error, why)
            throw PetPackageError.atlasUnreadable(manifest.spritesheetPath, detail: why)
        }

        let profile: CompatibilityProfile
        do {
            profile = try manifest.resolveProfile(atlasWidth: metadata.width, atlasHeight: metadata.height)
        } catch {
            let why = Self.detail(of: error)
            report.add("manifest", .error, why)
            throw PetPackageError.atlasUnreadable(manifest.spritesheetPath, detail: why)
        }

        let definition = PetDefinition(
            manifest: manifest,
            profile: profile,
            root: root,
            spritesheetURL: spritesheetURL
        )

        guard decodeAtlas else {
            return LoadedPetPackage(definition: definition, atlas: nil, report: report)
        }

        // 5. Pixels.
        let bitmap: RGBAAtlasBitmap
        do {
            bitmap = try AtlasImageDecoder.loadRGBA(at: spritesheetURL)
        } catch {
            report.add("atlas", .error, "\(error)")
            return LoadedPetPackage(definition: definition, atlas: nil, report: report)
        }
        report.merge(atlasValidator.validate(bitmap, profile: profile))

        return LoadedPetPackage(definition: definition, atlas: bitmap, report: report)
    }
}
