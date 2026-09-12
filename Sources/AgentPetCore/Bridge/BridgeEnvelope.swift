import Foundation

/// Facts about the process that ran the shim.
///
/// The shim is spawned by the agent, so its parent *is* the agent. That makes
/// `ppid` the one reliable correlation handle available without Accessibility
/// permissions or any cooperation from the agent.
public struct BridgeProcessInfo: Codable, Sendable, Equatable {
    public let pid: Int32
    public let ppid: Int32
    /// Controlling terminal, when the process has one.
    public let tty: String?

    public init(pid: Int32, ppid: Int32, tty: String?) {
        self.pid = pid
        self.ppid = ppid
        self.tty = tty
    }
}

public enum BridgeDecodeError: Error, Equatable, Sendable {
    case unsupportedVersion(received: Int, supported: Int)
    case malformed(String)
    case missingField(String)
    case payloadTooLarge(Int, limit: Int)
}

/// What the shim sends over the socket.
///
/// The agent's own payload is carried through **unparsed** as raw bytes. The
/// shim must never fail because an agent changed its JSON shape, and a decode
/// error belongs to one adapter rather than to the transport.
public struct BridgeEnvelope: Codable, Sendable, Equatable {

    public static let currentVersion = 1
    /// A hook payload is a few kilobytes at most. The cap stops a runaway or
    /// hostile producer from making the runtime allocate without bound.
    public static let maximumPayloadBytes = 1 << 20

    public let v: Int
    public let shimVersion: String
    public let agentID: String
    public let eventName: String
    public let receivedAt: Date
    public let proc: BridgeProcessInfo?
    /// The agent's stdout/stdin payload, verbatim.
    public let rawPayload: Data

    public init(
        agentID: String,
        eventName: String,
        receivedAt: Date,
        proc: BridgeProcessInfo?,
        rawPayload: Data,
        shimVersion: String = BridgeEnvelope.defaultShimVersion,
        version: Int = BridgeEnvelope.currentVersion
    ) {
        self.v = version
        self.shimVersion = shimVersion
        self.agentID = agentID
        self.eventName = eventName
        self.receivedAt = receivedAt
        self.proc = proc
        self.rawPayload = rawPayload
    }

    /// The shim passes its own version explicitly; this is only a default for
    /// callers that have nothing more specific to say.
    public static let defaultShimVersion = "0.1.0"

    public var payloadUTF8: String? {
        String(data: rawPayload, encoding: .utf8)
    }

    // MARK: - Wire format

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public func encoded() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    /// Decodes a frame from the wire.
    ///
    /// An unrecognised version is a hard error rather than a best-effort parse.
    /// A future shim sending a field this build does not understand would
    /// otherwise be silently misread.
    public static func decode(from data: Data) throws -> BridgeEnvelope {
        guard let probe = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BridgeDecodeError.malformed("frame is not a JSON object")
        }
        if let version = probe["v"] as? Int, version != currentVersion {
            throw BridgeDecodeError.unsupportedVersion(received: version, supported: currentVersion)
        }
        for field in ["agentID", "eventName"] where probe[field] == nil {
            throw BridgeDecodeError.missingField(field)
        }

        let envelope: BridgeEnvelope
        do {
            envelope = try makeDecoder().decode(BridgeEnvelope.self, from: data)
        } catch {
            throw BridgeDecodeError.malformed(String(describing: error))
        }

        guard envelope.rawPayload.count <= maximumPayloadBytes else {
            throw BridgeDecodeError.payloadTooLarge(
                envelope.rawPayload.count, limit: Self.maximumPayloadBytes
            )
        }
        return envelope
    }
}
