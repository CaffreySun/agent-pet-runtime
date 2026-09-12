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

        print("Search paths:")
        for path in PetLibrary.searchPaths {
            let exists = FileManager.default.fileExists(atPath: path.path)
            print("  \(exists ? "✓" : "✗") \(path.path)")
        }
        print("")

        let entries = PetLibrary.discover()
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

        if !loadedAny {
            print("No playable pet. The window would show nothing.")
            return 1
        }

        let size = PetWindow.defaultSize
        print("Displays (\(NSScreen.screens.count)):")
        for (index, screen) in NSScreen.screens.enumerated() {
            let marker = screen == NSScreen.screens.first ? "primary" : "       "
            let focused = screen == NSScreen.main ? "  <- keyboard focus" : ""
            print("  [\(index)] \(marker) visible=\(fmt(screen.visibleFrame))"
                  + " full=\(fmt(screen.frame))\(focused)")
        }

        guard let screen = NSScreen.screens.first else {
            print("No displays are available to this process.")
            return 1
        }
        let origin = PetWindow.defaultOrigin(on: screen)
        print("Pet window would open at:  (\(Int(origin.x)), \(Int(origin.y))) "
              + "size \(Int(size.width))x\(Int(size.height)) on the primary display")

        let saved = UserDefaults.standard.string(forKey: "pet.window.origin")
        print("Saved window origin:       \(saved ?? "(none)")")

        if let exportIndex = CommandLine.arguments.firstIndex(of: "--export-frames"),
           exportIndex + 1 < CommandLine.arguments.count {
            exportFrames(to: CommandLine.arguments[exportIndex + 1], loader: loader, entries: entries)
        }

        return 0
    }

    /// Writes each track's first frame to disk. The quickest way to tell a
    /// rendering bug from a sprite-decoding bug.
    private static func exportFrames(
        to directory: String,
        loader: PetPackageLoader,
        entries: [PetLibrary.Entry]
    ) {
        guard let entry = entries.first else { return }
        let out = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        do {
            let loaded = try loader.load(from: entry.root)
            guard let atlas = loaded.atlas else { return }
            let frames = try SpriteFrames(bitmap: atlas, profile: loaded.definition.profile)

            for (name, images) in frames.frames.sorted(by: { $0.key < $1.key }) {
                guard let image = images.first else { continue }
                let url = out.appendingPathComponent("\(name).png")
                guard let dest = CGImageDestinationCreateWithURL(
                    url as CFURL, "public.png" as CFString, 1, nil
                ) else { continue }
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
                print("  exported \(name).png  \(image.width)x\(image.height)")
            }
        } catch {
            print("  export failed: \(error)")
        }
    }

    private static func fmt(_ rect: NSRect) -> String {
        "(\(Int(rect.minX)), \(Int(rect.minY))) \(Int(rect.width))x\(Int(rect.height))"
    }
}
