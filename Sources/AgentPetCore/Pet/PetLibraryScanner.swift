import Foundation

/// The pet library as it exists on disk: what can be listed, and what cannot.
///
/// Discovery used to drop whatever it could not load, which left a folder the
/// user can see in the Finder invisible everywhere — no row in the manager, no
/// line in the log, nothing to act on. A package is refused for good reasons
/// (a `spriteVersionNumber` contradicting the sheet's size, a manifest that
/// decodes to the wrong types, a spritesheet that is not an image; Codex's own
/// TUI refuses them too), but the *reason* is the user's, so every skip carries
/// one and `--diagnose` prints it.
///
/// This is the pure half of discovery: which directories to scan is the app's
/// business, what to do with what they contain is this.
public enum PetLibraryScanner {

    /// One directory to scan, and the manifest name packages in it must carry.
    ///
    /// Codex reads two: `pets/` with `pet.json`, and the older `avatars/` with
    /// `avatar.json`. The name is required rather than inferred because a
    /// package in the wrong directory is a skip worth reporting, not a package
    /// to accept from the wrong place.
    public struct Source: Sendable, Equatable {
        public let directory: URL
        public let manifest: String

        public init(directory: URL, manifest: String) {
            self.directory = directory
            self.manifest = manifest
        }
    }

    /// A package that can be listed.
    public struct Entry: Sendable {
        public let name: String
        public let root: URL
        public let definition: PetDefinition
        public let warnings: [ValidationIssue]

        public var id: String { definition.id }

        public init(name: String, root: URL, definition: PetDefinition, warnings: [ValidationIssue]) {
            self.name = name
            self.root = root
            self.definition = definition
            self.warnings = warnings
        }
    }

    /// A folder that looks like a pet package — it carries a manifest — but
    /// will not be listed, and why.
    public struct Skipped: Sendable, Equatable {
        /// The folder's name, which is what the user sees in the Finder.
        public let name: String
        public let root: URL
        public let reason: String

        public init(name: String, root: URL, reason: String) {
            self.name = name
            self.root = root
            self.reason = reason
        }
    }

    public struct Result: Sendable {
        public let entries: [Entry]
        public let skipped: [Skipped]

        public init(entries: [Entry], skipped: [Skipped]) {
            self.entries = entries
            self.skipped = skipped
        }
    }

    /// Scans `sources` in order, first package for an id winning.
    ///
    /// A folder with no manifest at all is not a pet — a build run, a loose
    /// download, a stray directory — and Codex would not offer it either, so
    /// it is passed over in silence. Everything that carries a manifest and
    /// still cannot be listed is reported: that folder is a pet the user
    /// installed and expects to see.
    public static func scan(
        sources: [Source],
        loader: PetPackageLoader = PetPackageLoader()
    ) -> Result {
        var seenIDs = Set<String>()
        var entries: [Entry] = []
        var skipped: [Skipped] = []

        for source in sources {
            for child in children(of: source.directory) {
                guard carriesManifest(child) else { continue }

                let loaded: LoadedPetPackage
                do {
                    loaded = try loader.load(
                        from: child, decodeAtlas: false, manifestFileName: source.manifest
                    )
                } catch PetPackageError.manifestNotFound {
                    // It has a manifest, just not this directory's — `pets/`
                    // reads `pet.json`, `avatars/` reads `avatar.json`.
                    skipped.append(Skipped(
                        name: child.lastPathComponent, root: child,
                        reason: "no \(source.manifest) in this folder"
                    ))
                    continue
                } catch let error as PetPackageError {
                    skipped.append(Skipped(
                        name: child.lastPathComponent, root: child, reason: error.message
                    ))
                    continue
                } catch {
                    skipped.append(Skipped(
                        name: child.lastPathComponent, root: child, reason: "\(error)"
                    ))
                    continue
                }

                guard loaded.isValid else {
                    let reasons = loaded.report.errors.map(\.message).joined(separator: "; ")
                    skipped.append(Skipped(
                        name: child.lastPathComponent, root: child,
                        reason: reasons.isEmpty ? "the package did not validate" : reasons
                    ))
                    continue
                }

                // The manifest id wins over the directory name — they differ in
                // real packages (pet-ben-hill ships id `real-face-pet`), and
                // the manifest is authoritative. Two packages claiming one id
                // means a hand-made copy; the first in sort order wins and the
                // other is not listed twice.
                let id = loaded.definition.id
                if seenIDs.contains(id) {
                    // The same folder in both directories: keep the pets/ copy.
                    guard source.manifest == PetPackageLoader.manifestFileName,
                          let index = entries.firstIndex(where: {
                              $0.root.lastPathComponent == child.lastPathComponent
                          })
                    else {
                        skipped.append(Skipped(
                            name: child.lastPathComponent, root: child,
                            reason: "another package already claims the id “\(id)”"
                        ))
                        continue
                    }
                    seenIDs.remove(entries[index].id)
                    entries.remove(at: index)
                }

                seenIDs.insert(id)
                entries.append(Entry(
                    name: loaded.definition.displayName,
                    root: child,
                    definition: loaded.definition,
                    warnings: loaded.report.warnings
                ))
            }
        }
        return Result(entries: entries, skipped: skipped)
    }

    /// Whether the folder holds a manifest under either name. Checked before
    /// loading so that "this is not a pet at all" and "this pet has the wrong
    /// manifest for this directory" stay distinguishable.
    private static func carriesManifest(_ directory: URL) -> Bool {
        [PetPackageLoader.manifestFileName, PetPackageLoader.legacyManifestFileName].contains {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
    }

    private static func children(of directory: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return children.sorted { $0.lastPathComponent < $1.lastPathComponent }.filter {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDir)
                && isDir.boolValue
        }
    }
}
