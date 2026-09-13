import Foundation

/// The message the pet shows beside itself, ported from Codex's ambient pet.
///
/// Codex's terminal pets carry a notification with four states and a second
/// line of specifics; the Codex app shows the same vocabulary beside its
/// sprite. The TUI currently reserves the space and picks the animation but
/// does not draw the text (its PR says the overlay is disabled), so the model
/// below — kinds, labels, bodies, lifetimes — is the authoritative part, and
/// this runtime draws it.
public enum PetNotificationKind: String, CaseIterable, Sendable {

    case running
    case waiting
    case review
    case failed

    /// The one-line status. Wording is Codex's own, down to the case.
    public var label: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Needs input"
        case .review:  return "Ready"
        case .failed:  return "Blocked"
        }
    }

    /// What the second line says when the event carried nothing specific.
    ///
    /// For three of the four kinds this is the label and the message collapses
    /// to a single line; `running` is the exception — Codex shows
    /// "Running / Thinking" rather than "Running" alone.
    public var fallbackBody: String {
        switch self {
        case .running: return "Thinking"
        case .waiting: return "Needs input"
        case .review:  return "Ready"
        case .failed:  return "Blocked"
        }
    }

    /// How long a message stays after it was set, from Codex's constants: a
    /// running task goes quiet after three minutes, a failure is worth an
    /// hour's reminder, a pending decision most of a day, and a finished one
    /// stays until something replaces it.
    public var lifetime: TimeInterval {
        switch self {
        case .running: return 3 * 60
        case .failed:  return 60 * 60
        case .waiting: return 24 * 60 * 60
        case .review:  return 7 * 24 * 60 * 60
        }
    }

    /// The kind a session state speaks in, or `nil` when it says nothing.
    ///
    /// Codex distinguishes two ways of waiting on a human — an approval and a
    /// question — only in the body text; both are "Needs input".
    public static func forState(_ state: AgentState) -> PetNotificationKind? {
        switch state {
        case .running:                          return .running
        case .waitingInput, .waitingApproval:   return .waiting
        case .completed:                        return .review
        case .failed:                           return .failed
        case .idle, .paused, .unknown:          return nil
        }
    }
}

/// One message shown beside the pet.
public struct PetNotification: Sendable, Equatable {

    public let kind: PetNotificationKind
    /// The second line, resolved at creation exactly as Codex resolves it.
    public let body: String
    public let setAt: Date

    public init(kind: PetNotificationKind, body: String? = nil, setAt: Date) {
        let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.kind = kind
        self.body = trimmed.isEmpty ? kind.fallbackBody : trimmed
        self.setAt = setAt
    }

    /// The second line says something the label does not — the same
    /// comparison Codex uses to decide between a one- and a two-line message.
    public var showsDetail: Bool { body != kind.label }

    /// A message outlives its usefulness: Codex stamps each one and drops it
    /// once its kind's lifetime has passed.
    public func isExpired(at now: Date) -> Bool {
        now.timeIntervalSince(setAt) >= kind.lifetime
    }
}
