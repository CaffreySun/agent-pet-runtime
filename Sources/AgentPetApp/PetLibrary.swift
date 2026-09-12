import AgentPetCore
import Foundation

/// Finds pet packages on disk.
///
/// `~/.codex/pets/` is the published install location used by the Codex
/// toolchain. It is treated strictly as a *read-only source*: pets found there
/// are loaded in place for now and will later be imported into the runtime's
/// own store. Nothing here ever writes to it.
struct PetLibrary {

    struct Entry {
        let name: String
        let root: URL
        let definition: PetDefinition
        let warnings: [ValidationIssue]
    }

    /// Directories searched, in priority order.
    static var searchPaths: [URL] {
        var paths: [URL] = []
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            paths.append(URL(fileURLWithPath: codexHome).appendingPathComponent("pets"))
        }
        paths.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets"))
        paths.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentPetRuntime/pets"))
        return paths
    }

    /// Loads only what is needed to name a pet. Atlases are decoded lazily by
    /// the caller so listing a library never rasterises every sheet.
    static func discover(loader: PetPackageLoader = PetPackageLoader()) -> [Entry] {
        var seen = Set<String>()
        var entries: [Entry] = []

        for directory in searchPaths {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []

            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir),
                      isDir.boolValue
                else { continue }

                guard let loaded = try? loader.load(from: child, decodeAtlas: false),
                      loaded.isValid
                else { continue }

                // The manifest id wins over the directory name — they differ in
                // real packages, and the manifest is authoritative.
                guard seen.insert(loaded.definition.id).inserted else { continue }

                entries.append(Entry(
                    name: loaded.definition.displayName,
                    root: child,
                    definition: loaded.definition,
                    warnings: loaded.report.warnings
                ))
            }
        }
        return entries
    }

    /// Fully loads one entry, including its pixels.
    static func load(_ entry: Entry, loader: PetPackageLoader = PetPackageLoader()) throws -> LoadedPetPackage {
        try loader.load(from: entry.root)
    }
}
