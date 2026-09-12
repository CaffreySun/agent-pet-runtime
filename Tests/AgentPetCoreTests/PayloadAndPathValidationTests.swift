import Foundation
import Testing
@testable import AgentPetCore

@Suite("Payload classification")
struct PayloadClassificationTests {

    @Test("package files are allowed")
    func allowed() {
        for name in ["pet.json", "spritesheet.webp", "使用说明.txt", "README.md", "icon.png"] {
            #expect(PayloadValidator.classify(name: name, mode: 0o644) == .allowed, "\(name) should be allowed")
        }
    }

    @Test("junk is ignored rather than treated as a threat")
    func ignored() {
        for name in [".DS_Store", ".gitignore", "LICENSE"] {
            #expect(PayloadValidator.classify(name: name, mode: 0o644) == .ignored, "\(name) should be ignored")
        }
    }

    @Test("executable extensions are rejected")
    func executableExtensions() {
        for name in ["install.sh", "run.command", "Evil.app", "lib.dylib", "x.so", "a.scpt"] {
            guard case .rejected(.executableExtension) = PayloadValidator.classify(name: name, mode: 0o644) else {
                Issue.record("\(name) should be rejected")
                continue
            }
        }
    }

    @Test("the executable bit rejects a file whatever its extension")
    func executableBit() {
        #expect(PayloadValidator.classify(name: "helper.txt", mode: 0o755)
                == .rejected(.executablePermission(path: "helper.txt")))
        #expect(PayloadValidator.classify(name: "helper.json", mode: 0o711)
                == .rejected(.executablePermission(path: "helper.json")))
    }

    @Test("a non-executable mode is fine")
    func nonExecutableMode() {
        #expect(PayloadValidator.classify(name: "pet.json", mode: 0o600) == .allowed)
        #expect(PayloadValidator.classify(name: "pet.json", mode: 0o644) == .allowed)
    }

    @Test("an unknown extension is rejected, not waved through")
    func unknownExtension() {
        #expect(PayloadValidator.classify(name: "payload.bin", mode: 0o644)
                == .rejected(.disallowedExtension(ext: "bin")))
    }

    @Test("extension matching is case-insensitive")
    func caseInsensitiveExtension() {
        #expect(PayloadValidator.classify(name: "SPRITE.WEBP", mode: 0o644) == .allowed)
        #expect(PayloadValidator.classify(name: "Evil.SH", mode: 0o644)
                == .rejected(.executableExtension(ext: "sh")))
    }

    @Test("a file with no mode is judged on its extension alone")
    func missingMode() {
        #expect(PayloadValidator.classify(name: "pet.json", mode: nil) == .allowed)
        #expect(PayloadValidator.classify(name: "x.sh", mode: nil)
                == .rejected(.executableExtension(ext: "sh")))
    }
}

@Suite("Path safety")
struct PathSafetyTests {

    @Test("ordinary relative paths are safe")
    func ordinary() throws {
        for path in ["spritesheet.webp", "images/sheet.webp", "./sheet.webp", "a/b/c.png"] {
            try PathSafetyValidator.isLexicallySafe(path)
        }
    }

    @Test("absolute paths are rejected")
    func absolute() {
        for path in ["/etc/passwd", "/tmp/x.webp", "\\windows\\system32"] {
            #expect(throws: PathSafetyError.self) { try PathSafetyValidator.isLexicallySafe(path) }
        }
    }

    @Test("traversal is rejected however it is spelled")
    func traversal() {
        for path in ["../secret", "a/../../secret", "a/b/../../../etc/passwd", ".."] {
            #expect(throws: PathSafetyError.escapesPackageRoot(path)) {
                try PathSafetyValidator.isLexicallySafe(path)
            }
        }
    }

    @Test("a null byte is rejected")
    func nullByte() {
        #expect(throws: PathSafetyError.self) {
            try PathSafetyValidator.isLexicallySafe("pet\u{0}.json")
        }
    }

    @Test("an empty path is rejected")
    func empty() {
        #expect(throws: PathSafetyError.self) { try PathSafetyValidator.isLexicallySafe("") }
    }

    @Test("a safe path resolves inside the root")
    func resolvesInsideRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/petpackage")
        let resolved = try PathSafetyValidator().resolve("spritesheet.webp", within: root)
        #expect(resolved.path == "/tmp/petpackage/spritesheet.webp")
    }

    @Test("interior dot segments resolve without escaping")
    func interiorDots() throws {
        let root = URL(fileURLWithPath: "/tmp/petpackage")
        let resolved = try PathSafetyValidator().resolve("./images/../sheet.webp", within: root)
        #expect(resolved.path == "/tmp/petpackage/sheet.webp")
    }

    @Test("a symlink anywhere along the path is refused")
    func symlinkEscape() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("petpath-\(UUID().uuidString)")
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let escape = sub.appendingPathComponent("escape.webp")
        try FileManager.default.createSymbolicLink(
            at: escape, withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
        )

        #expect(throws: PathSafetyError.symbolicLink("escape.webp")) {
            try PathSafetyValidator().resolve("sub/escape.webp", within: root)
        }
    }

    @Test("a genuinely missing file is not reported as unsafe")
    func missingFileIsNotUnsafe() throws {
        let root = URL(fileURLWithPath: "/tmp/petpackage-not-here-\(UUID().uuidString)")
        let resolved = try PathSafetyValidator().resolve("spritesheet.webp", within: root)
        #expect(resolved.lastPathComponent == "spritesheet.webp")
    }
}

@Suite("Payload directory walk")
struct PayloadDirectoryTests {

    private func makePackage() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("petpayload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("a realistic package with docs and residue passes")
    func realisticPackage() throws {
        let root = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        let fm = FileManager.default
        try Data("{}".utf8).write(to: root.appendingPathComponent("pet.json"))
        try Data([0]).write(to: root.appendingPathComponent("spritesheet.webp"))
        try Data("notes".utf8).write(to: root.appendingPathComponent("使用说明.txt"))
        try Data("x".utf8).write(to: root.appendingPathComponent(".DS_Store"))

        // Build residue that real packages contain.
        let run = root.appendingPathComponent("run/prompts")
        try fm.createDirectory(at: run, withIntermediateDirectories: true)
        try Data("p".utf8).write(to: run.appendingPathComponent("row.md"))
        try Data("x".utf8).write(to: root.appendingPathComponent("run/script.sh"))

        let report = PayloadValidator().validate(packageRoot: root)
        #expect(report.isValid, "\(report.errors)")
    }

    @Test("a script at the package root is caught")
    func scriptAtRoot() throws {
        let root = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("#!/bin/sh".utf8).write(to: root.appendingPathComponent("install.sh"))
        let report = PayloadValidator().validate(packageRoot: root)
        #expect(!report.isValid)
    }

    @Test("a symlink is caught")
    func symlinkCaught() throws {
        let root = try makePackage()
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.webp"),
            withDestinationURL: URL(fileURLWithPath: "/etc/passwd")
        )
        let report = PayloadValidator().validate(packageRoot: root)
        #expect(!report.isValid)
        #expect(report.errors.contains { $0.message.contains("symbolic link") })
    }
}
