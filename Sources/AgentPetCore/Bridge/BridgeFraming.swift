import Darwin
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

    /// True when something is accepting connections at `url`.
    ///
    /// `connect` is the only honest test. A socket file left behind by a
    /// crashed run exists but refuses connections — that one is ours to remove
    /// — while a live runtime answers, and its socket is not ours to take.
    /// Nothing is sent: the connection is closed again immediately, and the
    /// server treats it as a peer that arrived and left.
    public static func hasListener(at url: URL) -> Bool {
        guard url.path.utf8.count <= maximumPathBytes else { return false }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(url.path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { destination.copyBytes(from: $0) }
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return connected == 0
    }
}

public enum BridgeSocketError: Error, Equatable, Sendable, CustomStringConvertible {
    case pathTooLong(path: String, bytes: Int, limit: Int)
    case cannotCreateSocket(errno: Int32)
    case cannotBind(path: String, errno: Int32)
    case cannotListen(errno: Int32)
    case cannotConnect(path: String, errno: Int32)
    /// Something is accepting connections at `path`: this user's other
    /// runtime. The path is how every hook finds the pet, so taking it over is
    /// not an option — see `BridgeServer.start()`.
    case alreadyRunning(path: String)

    /// These reach the user through the Event Bridge menu and the diagnostics
    /// bundle, so they say what happened rather than which case was thrown.
    public var description: String {
        switch self {
        case let .pathTooLong(path, bytes, limit):
            return "\(path) is \(bytes) bytes, over the \(limit)-byte limit for a socket path."
        case let .cannotCreateSocket(errno):
            return "Could not create the bridge socket (errno \(errno))."
        case let .cannotBind(path, errno):
            return "Could not bind \(path) (errno \(errno))."
        case let .cannotListen(errno):
            return "Could not listen on the bridge socket (errno \(errno))."
        case let .cannotConnect(path, errno):
            return "Could not connect to \(path) (errno \(errno))."
        case let .alreadyRunning(path):
            return "Another Agent Pet Runtime is already receiving events on \(path). "
                + "This one runs without the bridge; quit one of them."
        }
    }
}
