import AgentPetCore
import AppKit
import Foundation

/// Finds pet packages on disk.
///
/// There is exactly one place pets live: Codex's own home — `$CODEX_HOME`, or
/// `~/.codex` when that is unset. That is where the Codex TUI looks, where
/// `npx codex-pets add` installs, and where the hatch-pet skill writes. The
/// runtime keeps no store of its own: it reads these directories and never
/// writes to them, so anything added, updated, or removed with Codex's own
/// tooling shows up here unmodified.
///
/// Codex reads two directories under that home, and so does this: `pets/`,
/// whose packages carry `pet.json`, and the older `avatars/`, whose packages
/// carry `avatar.json`. Both are the same format.
struct PetLibrary {

    /// Which directories to scan is this file's job; deciding what a directory
    /// holds, and why a folder in it was left out, is `PetLibraryScanner`'s, in
    /// Core, where it can be tested without a screen.
    typealias Entry = PetLibraryScanner.Entry

    /// `CODEX_HOME` replaces `~/.codex` rather than adding to it, matching the
    /// `codex-pets` CLI and the hatch-pet skill. Searching both would show a
    /// pet the terminal Codex cannot actually load.
    static var codexHome: URL {
        if let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"] {
            return URL(fileURLWithPath: codexHome)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    /// Where pets are normally installed, and what the UI offers to open.
    static var petsDirectory: URL { codexHome.appendingPathComponent("pets") }

    /// The pre-`pets/` location. Still read; never written.
    static var avatarsDirectory: URL { codexHome.appendingPathComponent("avatars") }

    /// The directories Codex scans, in the order it scans them. `pets/` comes
    /// last so that a folder present in both — one migrated from the old
    /// layout to the new — resolves to the newer package, as it does in Codex.
    private static var sources: [PetLibraryScanner.Source] {
        [
            PetLibraryScanner.Source(
                directory: avatarsDirectory, manifest: PetPackageLoader.legacyManifestFileName
            ),
            PetLibraryScanner.Source(
                directory: petsDirectory, manifest: PetPackageLoader.manifestFileName
            ),
        ]
    }

    /// The library, plus the folders that look like pets and cannot be listed.
    ///
    /// `--diagnose` prints the second half; nothing else uses it, because a
    /// pet the user cannot play is not something the pet itself can show.
    static func scan(loader: PetPackageLoader = PetPackageLoader()) -> PetLibraryScanner.Result {
        PetLibraryScanner.scan(sources: sources, loader: loader)
    }

    /// Loads only what is needed to name a pet. Atlases are decoded lazily by
    /// the caller so listing a library never rasterises every sheet.
    static func discover(loader: PetPackageLoader = PetPackageLoader()) -> [Entry] {
        scan(loader: loader).entries
    }

    /// Fully loads one entry, including its pixels.
    static func load(_ entry: Entry, loader: PetPackageLoader = PetPackageLoader()) throws -> LoadedPetPackage {
        try loader.load(from: entry.root)
    }

    /// A still of a pet's resting pose, drawn at the size a list row shows it.
    ///
    /// The list draws one row per installed pet. Holding a decoded atlas for
    /// each of them — 11 MB of pixels at 1536×1872, and the CGImage keeps its
    /// own copy — made the manager's memory a function of how many pets the
    /// user had installed, and AppKit keeps a closed window's view tree, so
    /// there was nothing to give it back. A thumbnail is a few kilobytes, and
    /// the atlas it came from is released as soon as the still has been drawn.
    static func thumbnail(of entry: Entry, fitting size: CGFloat = 44) -> NSImage? {
        guard let loaded = try? load(entry),
              let atlas = loaded.atlas,
              let frames = try? SpriteFrames(bitmap: atlas, profile: loaded.definition.profile),
              let pose = frames.frame(track: "idle", column: 0)
        else { return nil }

        let scale = size / CGFloat(max(pose.width, pose.height))
        let width = max(1, Int((CGFloat(pose.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(pose.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(pose, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: width, height: height))
    }
}
