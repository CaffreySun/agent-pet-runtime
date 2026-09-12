import Foundation

/// A pet package that has been parsed and validated enough to name.
public struct PetDefinition: Sendable, Equatable {
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
    case atlasUnreadable(String)
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

    public static let manifestFileName = "pet.json"

    /// Parse and validate a package. `decodeAtlas` skips the expensive pixel
    /// stage — useful for listing a library without rasterising every pet.
    public func load(from root: URL, decodeAtlas: Bool = true) throws -> LoadedPetPackage {
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
        let manifestURL = root.appendingPathComponent(Self.manifestFileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw PetPackageError.manifestNotFound(root.lastPathComponent)
        }

        let manifest: PetManifest
        do {
            manifest = try PetManifest.decode(from: Data(contentsOf: manifestURL))
        } catch {
            report.add("manifest", .error, "\(error)")
            // Nothing downstream can run without an id and a sprite path.
            throw PetPackageError.manifestInvalid(root.lastPathComponent, detail: "\(error)")
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
            report.add("atlas", .error, "\(error)")
            throw PetPackageError.atlasUnreadable(manifest.spritesheetPath)
        }

        let profile: CompatibilityProfile
        do {
            profile = try manifest.resolveProfile(atlasWidth: metadata.width, atlasHeight: metadata.height)
        } catch {
            report.add("manifest", .error, "\(error)")
            throw PetPackageError.atlasUnreadable(manifest.spritesheetPath)
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
