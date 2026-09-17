import AgentPetCore
import AppKit
import ImageIO
import Foundation

/// Headless self-check, run with `AgentPet --diagnose`.
///
/// Reports what the app can see of the machine — which is exactly the
/// information needed when the pet refuses to appear and nothing is obviously
/// wrong. Nothing here reads prompts, model output, or credentials.
enum Diagnose {

    static func run() -> Int32 {
        print("Agent Pet Runtime — diagnostics")
        print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("")

        // The directories Codex itself scans. A missing one is worth saying
        // out loud: it is the difference between "no pets" and "wrong path".
        let petsDirectory = PetLibrary.petsDirectory
        print("Pets directories (Codex's own):")
        for (directory, manifest) in [
            (petsDirectory, PetPackageLoader.manifestFileName),
            (PetLibrary.avatarsDirectory, PetPackageLoader.legacyManifestFileName),
        ] {
            let exists = FileManager.default.fileExists(atPath: directory.path)
            print("  \(exists ? "✓" : "✗") \(directory.path)  (\(manifest))")
        }
        print("")

        let scan = PetLibrary.scan()
        let entries = scan.entries
        print("Discovered \(entries.count) pet package(s):")
        let loader = PetPackageLoader()

        var loadedAny = false
        for entry in entries {
            print("  • \(entry.name)  [id=\(entry.definition.id)]")
            print("      profile: \(entry.definition.profile.rawValue) "
                  + "(\(entry.definition.profile.atlasWidth)x\(entry.definition.profile.atlasHeight))")
            print("      source:  \(entry.root.path)")

            do {
                let loaded = try loader.load(from: entry.root)
                if let atlas = loaded.atlas {
                    let frames = try SpriteFrames(bitmap: atlas, profile: loaded.definition.profile)
                    let playable = frames.frames.filter { !$0.value.isEmpty }
                    print("      frames:  \(playable.count) tracks, "
                          + "\(playable.reduce(0) { $0 + $1.value.count }) frames decoded")
                    loadedAny = true
                } else {
                    print("      frames:  atlas not decoded")
                }
            } catch {
                print("      ERROR:   \(error)")
            }

            for warning in entry.warnings {
                print("      warn:    \(warning.message)")
            }
        }
        print("")

        // Folders that hold a manifest and still cannot be listed. This is the
        // only place the reason is ever said out loud: the manager has no row
        // for a pet it will not load, and the log has nothing to log. A
        // declared version that contradicts the sheet, a manifest of the wrong
        // shape, a spritesheet that is not an image — all of them look from
        // outside like "my pet is missing".
        if !scan.skipped.isEmpty {
            print("Skipped \(scan.skipped.count) folder(s) that look like pets:")
            for skip in scan.skipped {
                print("  ✗ \(skip.name)  (\(skip.root.path))")
                print("      \(skip.reason)")
            }
            print("")
        }

        // Reporting a missing pet or a missing display *is* the diagnosis.
        // A non-zero exit here would say "the command failed" when it in fact
        // did its job, and would fail a CI smoke test on a bare machine.
        if !loadedAny {
            print("No playable pet. The window would show nothing.")
            print("")
            print("This is a complete diagnosis; install a pet package to see one:")
            print("  npx codex-pets add <pet-id>          (from codex-pets.net)")
            print("or drop any package folder into \(petsDirectory.path)")
            return 0
        }

        let petWidth = CGFloat(AppConfigStore().load().pet.width)
        let size = PetWindow.size(forWidth: petWidth)
        print("Displays (\(NSScreen.screens.count)):")
        for (index, screen) in NSScreen.screens.enumerated() {
            let marker = screen == NSScreen.screens.first ? "primary" : "       "
            let focused = screen == NSScreen.main ? "  <- keyboard focus" : ""
            print("  [\(index)] \(marker) visible=\(fmt(screen.visibleFrame))"
                  + " full=\(fmt(screen.frame))\(focused)")
        }

        guard let screen = NSScreen.screens.first else {
            print("No displays are available to this process.")
            print("")
            print("Expected on a CI runner or over ssh. The pet needs a window server.")
            return 0
        }
        let origin = PetWindow.defaultOrigin(on: screen)
        print("Pet window would open at:  (\(Int(origin.x)), \(Int(origin.y))) "
              + "size \(Int(size.width))x\(Int(size.height)) on the primary display "
              + "(a \(Int(petWidth))pt-wide pet)")

        let saved = UserDefaults.standard.string(forKey: "pet.window.origin")
        print("Saved window origin:       \(saved ?? "(none)")")

        if let exportIndex = CommandLine.arguments.firstIndex(of: "--export-frames"),
           exportIndex + 1 < CommandLine.arguments.count {
            exportFrames(to: CommandLine.arguments[exportIndex + 1], loader: loader, entries: entries)
        }

        return 0
    }

    /// Writes every track's frames to disk, one folder per pet.
    ///
    /// The quickest way to tell a rendering bug from a sprite-decoding bug,
    /// and the only way to see what a row actually contains — including the
    /// gaze rows, whose meaning is a matter of interpreting the art.
    private static func exportFrames(
        to directory: String,
        loader: PetPackageLoader,
        entries: [PetLibrary.Entry]
    ) {
        let out = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        for entry in entries {
            do {
                let loaded = try loader.load(from: entry.root)
                guard let atlas = loaded.atlas else { continue }
                let frames = try SpriteFrames(bitmap: atlas, profile: loaded.definition.profile)

                let petDirectory = out.appendingPathComponent(entry.definition.id)
                try? FileManager.default.createDirectory(
                    at: petDirectory, withIntermediateDirectories: true
                )

                var exported = 0
                for (name, images) in frames.frames.sorted(by: { $0.key < $1.key }) {
                    for (index, image) in images.enumerated() {
                        let url = petDirectory.appendingPathComponent("\(name)-c\(index).png")
                        guard let dest = CGImageDestinationCreateWithURL(
                            url as CFURL, "public.png" as CFString, 1, nil
                        ) else { continue }
                        CGImageDestinationAddImage(dest, image, nil)
                        CGImageDestinationFinalize(dest)
                        exported += 1
                    }
                }
                print("  \(entry.definition.id): \(exported) frames -> \(petDirectory.path)")
            } catch {
                print("  \(entry.name) export failed: \(error)")
            }
        }
    }

    private static func fmt(_ rect: NSRect) -> String {
        "(\(Int(rect.minX)), \(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height))"
    }
}
