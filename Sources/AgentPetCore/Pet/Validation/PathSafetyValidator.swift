import Foundation

public enum PathSafetyError: Error, Equatable, Sendable {
    case absolutePath(String)
    case escapesPackageRoot(String)
    case symbolicLink(String)
    case notFound(String)
}

/// Resolves a path declared inside a package and proves it stays inside.
///
/// A manifest is attacker-controlled input: `spritesheetPath` could be
/// `../../../../etc/passwd`, an absolute path, or a symlink pointing anywhere
/// on disk. All three must be rejected before anything is read.
public struct PathSafetyValidator: Sendable {
    public init() {}

    /// Lexical normalisation with no filesystem access.
    ///
    /// `..` is only dangerous if it survives normalisation. `./images/../sheet.webp`
    /// is an ordinary way to spell `sheet.webp` and must be accepted, so the
    /// check is on the *result*, not on the individual components.
    public static func normalize(_ relative: String) throws -> String {
        guard !relative.isEmpty else {
            throw PathSafetyError.notFound(relative)
        }
        guard !relative.hasPrefix("/") else {
            throw PathSafetyError.absolutePath(relative)
        }
        // A Windows-style drive or UNC prefix is nonsense on macOS and signals
        // a malformed or hostile manifest.
        guard !relative.hasPrefix("\\") else {
            throw PathSafetyError.absolutePath(relative)
        }
        guard !relative.contains("\0") else {
            throw PathSafetyError.escapesPackageRoot(relative)
        }

        var stack: [String] = []
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                // Popping past the root is the escape we are looking for.
                guard !stack.isEmpty else {
                    throw PathSafetyError.escapesPackageRoot(relative)
                }
                stack.removeLast()
            default:
                stack.append(String(component))
            }
        }

        let normalized = stack.joined(separator: "/")
        guard !normalized.isEmpty else {
            throw PathSafetyError.notFound(relative)
        }
        return normalized
    }

    public static func isLexicallySafe(_ relative: String) throws {
        _ = try normalize(relative)
    }

    /// Lexical check plus a symlink check on every component that exists.
    ///
    /// Components that do not exist are fine — the caller reports a missing
    /// file separately, and there is nothing to follow.
    ///
    /// Rejecting symlinks is what makes the lexical normalisation sound: a
    /// symlinked directory would let `a/../x` mean something different to the
    /// filesystem than it does on paper.
    public func resolve(_ relative: String, within root: URL) throws -> URL {
        let normalized = try Self.normalize(relative)

        let rootPath = root.standardizedFileURL.path
        let candidate = root.appendingPathComponent(normalized).standardizedFileURL
        let candidatePath = candidate.path

        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else {
            throw PathSafetyError.escapesPackageRoot(relative)
        }

        try assertNoSymlinkAlong(relative: normalized, root: root)
        return candidate
    }

    private func assertNoSymlinkAlong(relative: String, root: URL) throws {
        var current = root
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            current.appendPathComponent(String(component))
            guard FileManager.default.fileExists(atPath: current.path) else { continue }

            let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                throw PathSafetyError.symbolicLink(String(component))
            }
        }
    }
}
