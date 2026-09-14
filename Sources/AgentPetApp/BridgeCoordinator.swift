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

    /// Whether the bridge is actually taking connections right now.
    ///
    /// `status.isListening` says a server was started, which is not the same
    /// question: an accept loop that has ended leaves a socket that still
    /// accepts at the kernel and reads nothing, and the menu used to call that
    /// "Listening" while every hook was being refused or ignored. This is the
    /// one the UI asks.
    var isAccepting: Bool { server?.isAccepting ?? false }

    /// Whether events can reach the pet: a server that started, and an accept
    /// loop that is still there to take the connection.
    var isListening: Bool { status.isListening && isAccepting }

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

    /// Writes a record of every event to a file so what an agent actually
    /// sends can be read back instead of inferred. Enabled with
    /// `--log-events <path>`; off by default.
    var captureURL: URL?

    private func capture(_ envelope: BridgeEnvelope) {
        guard let captureURL else { return }
        EventCapture.append(EventCapture.record(for: envelope), to: captureURL)
    }

    // MARK: - Lifecycle

    func start() {
        guard server == nil else { return }

        let socketURL = BridgeSocketLocation.defaultURL
        status.socketPath = socketURL.path

        let server = BridgeServer(
            socketURL: socketURL,
            handler: { [weak self] envelope in
                // The envelope is Sendable; everything else happens on the
                // main actor, in arrival order.
                Task { @MainActor [weak self] in self?.deliver(envelope) }
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
            // Worth saying out loud: a pet that receives nothing looks the same
            // from the outside whether the bridge failed or the agents are
            // quiet, and the menu is the only other place this shows up.
            if CommandLine.arguments.contains("--verbose") {
                FileHandle.standardError.write(Data(
                    "[pet] bridge: \(error)\n".utf8
                ))
            }
        }
        onStatusChange?()
    }

    /// Feeds one envelope through the normal path.
    ///
    /// Used by the socket and by the replay of events that arrived while the
    /// app was down, so a replayed event cannot be treated — or counted —
    /// differently from a live one. Running both here, on the main actor,
    /// also keeps replayed events in the order they happened.
    func deliver(_ envelope: BridgeEnvelope) {
        let events = normalizer.normalize(envelope)
        capture(envelope)
        handle(events, description: RecentEvent(
            agentID: envelope.agentID,
            eventName: envelope.eventName,
            kind: events.first?.kind,
            sessionID: events.first?.sessionID ?? "-",
            at: envelope.receivedAt
        ))
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
