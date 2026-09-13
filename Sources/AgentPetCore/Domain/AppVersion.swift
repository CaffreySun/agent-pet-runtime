import Foundation

/// A version like the ones in this project's tags: `0.5.3`.
///
/// Deliberately small — enough to answer "is the release on GitHub newer than
/// the bundle I am running", which is the only question the update check asks.
/// A leading `v` is accepted because tags carry one, missing components count
/// as zero (`1.2` == `1.2.0`), and anything after a hyphen is a pre-release
/// suffix and is ignored for ordering: `1.0.0-beta` is not "newer" than
/// `1.0.0` in any way that matters to a user deciding whether to upgrade.
public struct AppVersion: Sendable, Equatable, Comparable, CustomStringConvertible {

    public let components: [Int]

    /// `nil` when the text has no numbers to compare — a caller that cannot
    /// parse a version should say so rather than guess.
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let numeric = withoutPrefix.split(separator: "-", maxSplits: 1).first.map(String.init) ?? ""

        let parts = numeric.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var parsed: [Int] = []
        for part in parts {
            // A component that is not a number ends the parse: `1.2.x` is
            // `1.2`, which is a more useful answer than refusing the string.
            guard let value = Int(part.trimmingCharacters(in: .whitespaces)) else { break }
            parsed.append(value)
        }
        guard !parsed.isEmpty else { return nil }
        // Trailing zeros are padding, not information: `1.2` and `1.2.0` have
        // to compare *and* be equal, and one canonical form is how that stays
        // true without every comparison remembering to pad.
        while parsed.count > 1, parsed.last == 0 { parsed.removeLast() }
        self.components = parsed
    }

    public var description: String {
        components.map(String.init).joined(separator: ".")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let width = max(lhs.components.count, rhs.components.count)
        for index in 0..<width {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// Whether `candidate` (a tag, a release name) is a newer version than
    /// `current`. False whenever either side cannot be read: an unreadable
    /// version is not evidence of an upgrade.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let candidateVersion = AppVersion(candidate),
              let currentVersion = AppVersion(current)
        else { return false }
        return candidateVersion > currentVersion
    }
}
