import Foundation

/// What a session's own status line knows about it.
///
/// Hooks say *what is happening*; they carry no token counts, no cost, and no
/// names. Claude Code hands all of that to the status-line command instead,
/// and only there. From the documented payload (Claude Code 2.1.268):
///
///     context_window.used_percentage   pre-calculated, 0–100, null before the
///                                      first message
///     context_window.context_window_size / total_input_tokens
///     model.display_name               the model actually serving the session
///     effort.level                     reasoning effort, when the model has it
///     cost.total_cost_usd              session cost estimate
///     rate_limits.five_hour/seven_day  subscription windows consumed
///     session_name                     a /rename name, or the session title
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
    /// Tokens currently in the window, for a percentage that has to be
    /// recomputed against a known window.
    public var totalTokens: Int?
    public var windowSize: Int?
    /// The model serving the session, as Claude Code names it.
    public var modelName: String?
    /// Reasoning effort level, when the model has one (`low`…`max`).
    public var effortLevel: String?
    /// Estimated session cost in USD.
    public var costUSD: Double?
    /// Subscription windows consumed, 0–100 each.
    public var fiveHourPercent: Double?
    public var sevenDayPercent: Double?
    /// The name the user gave the session, or the session title.
    public var sessionName: String?
    /// Repository or project directory name — the closest thing to a task
    /// title that exists without reading a transcript.
    public var projectName: String?
    public var capturedAt: Date

    public init(
        usedPercent: Double? = nil,
        totalTokens: Int? = nil,
        windowSize: Int? = nil,
        modelName: String? = nil,
        effortLevel: String? = nil,
        costUSD: Double? = nil,
        fiveHourPercent: Double? = nil,
        sevenDayPercent: Double? = nil,
        sessionName: String? = nil,
        projectName: String? = nil,
        capturedAt: Date
    ) {
        self.usedPercent = usedPercent
        self.totalTokens = totalTokens
        self.windowSize = windowSize
        self.modelName = modelName
        self.effortLevel = effortLevel
        self.costUSD = costUSD
        self.fiveHourPercent = fiveHourPercent
        self.sevenDayPercent = sevenDayPercent
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
            modelName: newer.modelName ?? modelName,
            effortLevel: newer.effortLevel ?? effortLevel,
            costUSD: newer.costUSD ?? costUSD,
            fiveHourPercent: newer.fiveHourPercent ?? fiveHourPercent,
            sevenDayPercent: newer.sevenDayPercent ?? sevenDayPercent,
            sessionName: newer.sessionName ?? sessionName,
            projectName: newer.projectName ?? projectName,
            capturedAt: max(capturedAt, newer.capturedAt)
        )
    }

    /// Reads the reduced status-line payload the shim sends.
    ///
    /// Deliberately a small flat parser over an allowlist of keys: the shim
    /// already drops everything else, and a status-line payload contains the
    /// transcript path, git worktree paths, prompt-cache internals and other
    /// session state this app has no business copying anywhere.
    public static func fromStatusPayload(
        _ payload: [String: Any],
        at date: Date
    ) -> SessionContext? {
        let percent = number(payload["used_percentage"])
        let tokens = integer(payload["tokens"])
        let window = integer(payload["window"])
        let model = string(payload["model"])
        let effort = string(payload["effort"])
        let cost = number(payload["cost_usd"])
        let fiveHour = number(payload["limit_5h"])
        let sevenDay = number(payload["limit_7d"])
        let name = string(payload["session_name"])
        let project = string(payload["project"])

        guard percent != nil || tokens != nil || model != nil || name != nil
            || project != nil || cost != nil
        else { return nil }

        return SessionContext(
            usedPercent: percent,
            totalTokens: tokens,
            windowSize: window,
            modelName: model,
            effortLevel: effort,
            costUSD: cost,
            fiveHourPercent: fiveHour,
            sevenDayPercent: sevenDay,
            sessionName: name,
            projectName: project,
            capturedAt: date
        )
    }

    // MARK: - Display

    /// The model, with its reasoning effort when the model has one.
    ///
    /// Formatting lives here rather than in the drawing code so the strings
    /// can be asserted without a screen.
    public var modelLabel: String? {
        guard let modelName else { return nil }
        guard let effortLevel, !effortLevel.isEmpty else { return modelName }
        return "\(modelName) · \(effortLevel)"
    }

    /// Cost at a glance: cents matter while a session is young, and once it is
    /// past ten dollars the cents are noise.
    public var costLabel: String? {
        guard let costUSD else { return nil }
        return costUSD < 10
            ? String(format: "$%.2f", costUSD)
            : String(format: "$%.1f", costUSD)
    }

    /// How much of the subscription windows is gone, 5-hour first because it
    /// is the one that runs out first.
    public var limitsLabel: String? {
        var parts: [String] = []
        if let fiveHourPercent { parts.append("5h \(Self.percentLabel(fiveHourPercent))") }
        if let sevenDayPercent { parts.append("7d \(Self.percentLabel(sevenDayPercent))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func percentLabel(_ percent: Double) -> String {
        "\(Int(percent.rounded()))%"
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    /// A whole number out of the payload, or nothing.
    ///
    /// `Int(someDouble)` traps on anything outside `Int64` — and
    /// `JSONSerialization` happily hands back a `Double` for a JSON integer
    /// that big, so a frame carrying `{"tokens": 9223372036854775808}` used to
    /// take the whole app down. A number we cannot read is a number we do not
    /// show.
    private static func integer(_ value: Any?) -> Int? {
        number(value).flatMap { Int(exactly: $0) }
    }

    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
