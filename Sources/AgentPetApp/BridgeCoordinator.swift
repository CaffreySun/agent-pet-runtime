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
