import AgentPetCore
import Foundation

/// Finds pet packages on disk.
///
/// There is exactly one place pets live: Codex's own pets directory —
/// `$CODEX_HOME/pets`, or `~/.codex/pets` when `CODEX_HOME` is unset. That is
/// where the Codex TUI looks, where `npx codex-pets add` installs, and where
/// the hatch-pet skill writes. The runtime keeps no store of its own: it reads
/// this directory and never writes to it, so anything added, updated, or
/// removed with Codex's own tooling shows up here unmodified.
struct PetLibrary {

    struct Entry {
        let name: String
        let root: URL
        let definition: PetDefinition
        let warnings: [ValidationIssue]

        var id: String { definition.id }
    }

    /// The one directory Codex itself reads.
    ///
    /// `CODEX_HOME` replaces `~/.codex` rather than adding to it, matching the
    /// `codex-pets` CLI and the hatch-pet skill. Searching both would show a
    /// pet the terminal Codex cannot actually load.
    static var petsDirectory: URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            return URL(fileURLWithPath: codexHome).appendingPathComponent("pets")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets")
    }

    /// Loads only what is needed to name a pet. Atlases are decoded lazily by
    /// the caller so listing a library never rasterises every sheet.
    ///
    /// Anything the loader rejects is skipped rather than shown: a directory
    /// without `pet.json` (a build run, a loose download) is not a pet, and
    /// the Codex TUI would not offer it either.
    static func discover(loader: PetPackageLoader = PetPackageLoader()) -> [Entry] {
        let directory = petsDirectory
        let children = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []

        var seen = Set<String>()
        var entries: [Entry] = []

        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir),
                  isDir.boolValue
            else { continue }

            guard let loaded = try? loader.load(from: child, decodeAtlas: false),
                  loaded.isValid
            else { continue }

            // The manifest id wins over the directory name — they differ in
            // real packages, and the manifest is authoritative. Two folders
            // claiming the same id is possible when a pet was copied by hand;
            // the first in sort order wins and the other is not listed twice.
            guard seen.insert(loaded.definition.id).inserted else { continue }

            entries.append(Entry(
                name: loaded.definition.displayName,
                root: child,
                definition: loaded.definition,
                warnings: loaded.report.warnings
            ))
        }
        return entries
    }

    /// Fully loads one entry, including its pixels.
    static func load(_ entry: Entry, loader: PetPackageLoader = PetPackageLoader()) throws -> LoadedPetPackage {
        try loader.load(from: entry.root)
    }
}
