import CryptoKit
import Foundation

/// Content fingerprints, used to detect concurrent edits and to identify pet
/// packages.
public enum Hashing {

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Short form for logs, filenames, and anywhere a full digest is noise.
    public static func short(_ data: Data, length: Int = 8) -> String {
        String(sha256(data).prefix(length))
    }
}
