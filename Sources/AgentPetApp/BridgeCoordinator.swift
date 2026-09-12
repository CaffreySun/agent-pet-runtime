import AgentPetCore
import Foundation

/// Owns the bridge socket for the app and feeds arriving events into the
/// activity engine.
///
/// The server calls back on its own threads. Everything it touches is either
/// immutable or lock-protected, and delivery to the UI happens by hopping to
/// the main actor rather than by sharing state.
@MainActor
final class BridgeCoordinator {

    struct Status {
        var isListening = false
        var socketPath = ""
        var receivedCount = 0
        var lastEventDescription: String?
        var lastEventAt: Date?
        var error: String?
    }

    private(set) var status = Status()
    private var server: BridgeServer?

    /// Frames that arrived but could not be understood. Surfaced in
    /// diagnostics rather than thrown, since one agent's bad frame must not
    /// affect the others.
    var malformedFrameCount: Int { server?.malformedFrameCount ?? 0 }

    /// Called on the main actor for every normalized event.
    var onEvent: ((AgentEvent) -> Void)?
    var onStatusChange: (() -> Void)?

    /// Ring buffer of what has been seen, for the menu and diagnostics. Bounded
    /// so a long-running session cannot grow it without limit.
    private(set) var recent: [RecentEvent] = []
    private let recentLimit = 20

    struct RecentEvent: Sendable {
        let agentID: String
        let eventName: String
        let kind: AgentEventKind?
        let sessionID: String
        let at: Date
    }

    private let normalizer = EventNormalizer(profiles: AgentProfiles.all)

    /// Writes every raw envelope to a file, so what an agent actually sends can
    /// be read back instead of inferred. Enabled with `--log-events <path>`.
    var captureURL: URL?

    private func capture(_ envelope: BridgeEnvelope) {
        guard let captureURL else { return }
        let record: [String: Any] = [
            "agentID": envelope.agentID,
            "eventName": envelope.eventName,
            "receivedAt": ISO8601DateFormatter().string(from: envelope.receivedAt),
            "ppid": Int(envelope.proc?.ppid ?? 0),
            "tty": envelope.proc?.tty ?? "",
            "payload": envelope.payloadUTF8 ?? "<binary>",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: record),
              let line = String(data: data, encoding: .utf8)
        else { return }

        let text = line + "\n"
        if let handle = try? FileHandle(forWritingTo: captureURL) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: captureURL)
        }
    }

    func start() {
        guard server == nil else { return }

        let socketURL = BridgeSocketLocation.defaultURL
        status.socketPath = socketURL.path

        let server = BridgeServer(
            socketURL: socketURL,
            handler: { [weak self] envelope in
                // Hop to the main actor with only Sendable data in hand.
                let normalized = self?.normalizer.normalize(envelope) ?? []
                let description = RecentEvent(
                    agentID: envelope.agentID,
                    eventName: envelope.eventName,
                    kind: normalized.first?.kind,
                    sessionID: normalized.first?.sessionID ?? "-",
                    at: envelope.receivedAt
                )
                Task { @MainActor [weak self] in
                    self?.capture(envelope)
                    self?.handle(normalized, description: description)
                }
            },
            diagnostic: { message in
                Task { @MainActor [weak self] in
                    self?.status.error = message
                    self?.onStatusChange?()
                }
            }
        )

        do {
            try server.start()
            self.server = server
            status.isListening = true
            status.error = nil
        } catch {
            status.isListening = false
            status.error = "\(error)"
        }
        onStatusChange?()
    }

    func stop() {
        server?.stop()
        server = nil
        status.isListening = false
        onStatusChange?()
    }

    private func handle(_ events: [AgentEvent], description: RecentEvent) {
        status.receivedCount += 1
        status.lastEventAt = description.at
        status.lastEventDescription = "\(description.agentID) · \(description.eventName)"

        recent.insert(description, at: 0)
        if recent.count > recentLimit { recent.removeLast(recent.count - recentLimit) }

        for event in events { onEvent?(event) }
        onStatusChange?()
    }
}
