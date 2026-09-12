import Foundation

/// Splits a byte stream into frames.
///
/// Frames are newline-delimited JSON. The payload is base64 and the encoded
/// envelope is single-line by construction, so no escaping is needed and the
/// protocol stays readable with `nc -U`.
///
/// A stream-oriented socket delivers arbitrary chunk boundaries, so this
/// accumulates rather than assuming one read equals one frame.
public struct BridgeFrameDecoder: Sendable {
    private var buffer = Data()

    /// Refuses to buffer without bound. A peer that never sends a newline
    /// would otherwise grow this forever.
    public let maximumFrameBytes: Int

    public init(maximumFrameBytes: Int = BridgeEnvelope.maximumPayloadBytes * 2) {
        self.maximumFrameBytes = maximumFrameBytes
    }

    /// Feeds bytes in and returns whatever complete frames they completed.
    public mutating func append(_ chunk: Data) -> [Data] {
        buffer.append(chunk)

        var frames: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let frame = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if !frame.isEmpty {
                frames.append(Data(frame))
            }
        }

        if buffer.count > maximumFrameBytes {
            // Drop the partial frame rather than the connection: the peer may
            // still send well-formed frames afterwards.
            buffer.removeAll(keepingCapacity: false)
        }

        return frames
    }

    /// Bytes held back waiting for a newline. Exposed for tests and diagnostics.
    public var pendingByteCount: Int { buffer.count }
}

/// Where the bridge socket lives, and the constraints on that path.
///
/// `sockaddr_un.sun_path` is a fixed 104 bytes on macOS. A path that is too
/// long fails at `bind` with a truncation that is easy to misdiagnose, so the
/// length is checked up front with a message that says what is wrong.
public enum BridgeSocketLocation {

    public static let maximumPathBytes = 103  // 104 including the NUL terminator

    public static var defaultURL: URL {
        applicationSupportDirectory.appendingPathComponent("bridge.sock")
    }

    public static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AgentPetRuntime")
    }

    public static func validate(_ url: URL) throws {
        let length = url.path.utf8.count
        guard length <= maximumPathBytes else {
            throw BridgeSocketError.pathTooLong(path: url.path, bytes: length, limit: maximumPathBytes)
        }
    }
}

public enum BridgeSocketError: Error, Equatable, Sendable {
    case pathTooLong(path: String, bytes: Int, limit: Int)
    case cannotCreateSocket(errno: Int32)
    case cannotBind(path: String, errno: Int32)
    case cannotListen(errno: Int32)
    case cannotConnect(path: String, errno: Int32)
}
