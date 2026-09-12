import Foundation

public enum PayloadViolation: Error, Equatable, Sendable {
    case executableExtension(ext: String)
    case executablePermission(path: String)
    case disallowedExtension(ext: String)
}

/// How a file inside a package should be treated.
public enum PayloadVerdict: Equatable, Sendable {
    /// Part of the package.
    case allowed
    /// Present but irrelevant — junk, not a threat. Silently skipped.
    case ignored
    /// The package must not be installed.
    case rejected(PayloadViolation)
}

/// A pet package is a manifest plus images. It never carries code, so the
/// validator's job is to prove that and nothing more.
///
/// The rule set is intentionally an allowlist. Observed packages legitimately
/// contain `使用说明.txt`, `.DS_Store`, and whole `run/` directories of
/// intermediate build output, so a denylist alone would either reject valid
/// pets or let unknown payload types through.
public struct PayloadValidator: Sendable {

    public static let allowedExtensions: Set<String> = [
        "json", "webp", "png", "jpg", "jpeg", "gif", "txt", "md",
    ]

    public static let deniedExtensions: Set<String> = [
        "sh", "command", "app", "dylib", "so", "scpt", "workflow",
        "jar", "py", "rb", "pl", "php", "exe", "dmg", "pkg",
    ]

    /// Directories that are build residue rather than shipped content.
    public static let ignoredDirectoryNames: Set<String> = ["run", ".agentpet", "__MACOSX"]

    public init() {}

    /// Pure classification — no filesystem access, so it is cheap to test.
    ///
    /// `mode` is the POSIX permission bits; any execute bit rejects the file
    /// regardless of extension.
    public static func classify(name: String, mode: Int?) -> PayloadVerdict {
        if name.hasPrefix(".") { return .ignored }
        if name == ".DS_Store" { return .ignored }

        let ext = (name as NSString).pathExtension.lowercased()

        if let mode, mode & 0o111 != 0 {
            return .rejected(.executablePermission(path: name))
        }
        if !ext.isEmpty, deniedExtensions.contains(ext) {
            return .rejected(.executableExtension(ext: ext))
        }
        if ext.isEmpty {
            // A file with no extension inside a pet package is either junk or
            // something we cannot reason about. Treat it as junk rather than
            // guessing.
            return .ignored
        }
        if allowedExtensions.contains(ext) { return .allowed }
        return .rejected(.disallowedExtension(ext: ext))
    }

    /// Walks a package root and reports every violation. `run/` and other
    /// ignored directories are not descended into.
    public func validate(packageRoot: URL, fileManager: FileManager = .default) -> ValidationReport {
        var report = ValidationReport()

        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: packageRoot,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            report.add("payload", .error, "cannot read package directory")
            return report
        }

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = url.lastPathComponent

            if values?.isDirectory == true {
                if Self.ignoredDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                }
                continue
            }

            // A symlink is a way out of the package root; never follow it.
            if values?.isSymbolicLink == true {
                report.add("payload", .error, "symbolic link '\(name)' is not allowed in a pet package")
                continue
            }

            let mode = Self.permissionBits(at: url, fileManager: fileManager)
            switch Self.classify(name: name, mode: mode) {
            case .allowed, .ignored:
                break
            case .rejected(let violation):
                report.add("payload", .error, Self.describe(violation))
            }
        }

        return report
    }

    /// `posixPermissions` is not exposed through `URLResourceValues`, so the
    /// permission bits have to come from the older attributes API.
    static func permissionBits(at url: URL, fileManager: FileManager) -> Int? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let number = attributes[.posixPermissions] as? NSNumber
        else { return nil }
        return number.intValue
    }

    static func describe(_ violation: PayloadViolation) -> String {
        switch violation {
        case .executableExtension(let ext):
            return "file with executable extension '.\(ext)' is not allowed in a pet package"
        case .executablePermission(let path):
            return "'\(path)' has the executable bit set"
        case .disallowedExtension(let ext):
            return "unexpected file type '.\(ext)' in pet package"
        }
    }
}
