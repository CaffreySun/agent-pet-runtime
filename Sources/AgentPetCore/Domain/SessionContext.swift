import Foundation

/// What a session's own status line knows about it.
///
/// Hooks say *what is happening*; they carry no token counts and no names.
/// Claude Code hands that to the status-line command instead, and only there:
/// the payload documented by the installed build (2.1.268) is
///
///     context_window.used_percentage   pre-calculated, 0–100, null before the
///                                      first message
///     context_window.context_window_size
///     context_window.total_input_tokens
///     session_name                     set with /rename
///     workspace.repo.name              repository identity when cwd is in one
///
/// A session with no tap simply has no `SessionContext`, and the panel draws
/// nothing where it would have gone. Nothing here is required for the pet to
/// work.
public struct SessionContext: Sendable, Equatable {

    /// Claude Code's own number, not ours: it knows the context window for the
    /// current model, which is the one thing an outside reader cannot know —
    /// a gateway can serve models with windows this app has never heard of.
    public var usedPercent: Double?
    /// Tokens currently in the window, for tooltips and for a percentage that
    /// has to be recomputed against a known window.
    public var totalTokens: Int?
    public var windowSize: Int?
    /// The name the user gave the session, if they gave it one.
    public var sessionName: String?
    /// Repository or project directory name — the closest thing to a task
    /// title that exists without reading a transcript.
    public var projectName: String?
    public var capturedAt: Date

    public init(
        usedPercent: Double? = nil,
        totalTokens: Int? = nil,
        windowSize: Int? = nil,
        sessionName: String? = nil,
        projectName: String? = nil,
        capturedAt: Date
    ) {
        self.usedPercent = usedPercent
        self.totalTokens = totalTokens
        self.windowSize = windowSize
        self.sessionName = sessionName
        self.projectName = projectName
        self.capturedAt = capturedAt
    }

    /// A later reading fills in what it knows and keeps what it does not.
    ///
    /// Status-line invocations are frequent and not uniform — a session with
    /// no name reports none — so treating a missing field as a retraction
    /// would make the panel flicker between values and blanks.
    public func merging(_ newer: SessionContext) -> SessionContext {
        SessionContext(
            usedPercent: newer.usedPercent ?? usedPercent,
            totalTokens: newer.totalTokens ?? totalTokens,
            windowSize: newer.windowSize ?? windowSize,
            sessionName: newer.sessionName ?? sessionName,
            projectName: newer.projectName ?? projectName,
            capturedAt: max(capturedAt, newer.capturedAt)
        )
    }

    /// Reads the reduced status-line payload the shim sends.
    ///
    /// Deliberately a small flat parser over an allowlist of keys: the shim
    /// already drops everything else, and a status-line payload contains the
    /// transcript path, cost figures, and rate-limit state that this app has
    /// no business copying anywhere.
    public static func fromStatusPayload(
        _ payload: [String: Any],
        at date: Date
    ) -> SessionContext? {
        let percent = number(payload["used_percentage"])
        let tokens = number(payload["tokens"]).map(Int.init)
        let window = number(payload["window"]).map(Int.init)
        let name = string(payload["session_name"])
        let project = string(payload["project"])

        guard percent != nil || tokens != nil || name != nil || project != nil else {
            return nil
        }
        return SessionContext(
            usedPercent: percent,
            totalTokens: tokens,
            windowSize: window,
            sessionName: name,
            projectName: project,
            capturedAt: date
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
