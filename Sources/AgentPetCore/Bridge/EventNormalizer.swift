import Foundation

/// Maps one of an agent's hook event names onto a normalized kind.
///
/// Rules are evaluated in order and the first that applies wins, so a general
/// rule can be followed by narrower ones that override it.
public struct NormalizationRule: Codable, Sendable, Equatable {
    /// Hook event names this rule matches, e.g. `["PreToolUse", "PostToolUse"]`.
    public let matches: [String]
    public let kind: AgentEventKind
    /// Top-level payload key to read a human summary from, if present.
    public let summaryField: String?
    /// Top-level payload key to read a second line from, if present.
    ///
    /// Used for Claude Code's `last_assistant_message` on `Stop` — the field
    /// exists precisely so hooks do not have to read and parse a transcript.
    /// It becomes the pet's "Ready" message, and it is never written to an
    /// event capture: it is model output, which is the one thing the log
    /// allowlist exists to keep out of files.
    public let detailField: String?
    /// Top-level payload key holding the session id.
    public let sessionIDField: String?
    /// Top-level payload key holding the working directory.
    public let workingDirectoryField: String?

    /// Only applies when the payload's `notification_type` equals this.
    ///
    /// Claude Code reports several unrelated things through one `Notification`
    /// event, distinguished only by this field. Treating "a permission prompt"
    /// and "you have been idle a while" as the same state would leave the pet
    /// permanently asking for attention.
    public let whenNotificationType: String?

    /// Skips the rule when the payload lists a still-running background task.
    ///
    /// Claude Code fires `Stop` when the main agent yields, which happens while
    /// a background subagent is still working. Reporting that as a finished
    /// turn would make the pet announce completion in the middle of the job.
    public let suppressedByRunningBackgroundTask: Bool

    public init(
        matches: [String],
        kind: AgentEventKind,
        summaryField: String? = nil,
        detailField: String? = nil,
        sessionIDField: String? = nil,
        workingDirectoryField: String? = nil,
        whenNotificationType: String? = nil,
        suppressedByRunningBackgroundTask: Bool = false
    ) {
        self.matches = matches
        self.kind = kind
        self.summaryField = summaryField
        self.detailField = detailField
        self.sessionIDField = sessionIDField
        self.workingDirectoryField = workingDirectoryField
        self.whenNotificationType = whenNotificationType
        self.suppressedByRunningBackgroundTask = suppressedByRunningBackgroundTask
    }
}

/// Everything agent-specific about turning hook events into `AgentEvent`s.
///
/// This is data, not code, on purpose: the design requires that adding an agent
/// does not mean modifying the runtime core, and the differences between agents
/// really are just "which names, which keys".
public struct AgentProfile: Codable, Sendable, Equatable {
    public let agentID: String
    public let displayName: String
    public let rules: [NormalizationRule]
    /// Used when the payload carries no session id — a terminal-only agent
    /// still has to be trackable.
    public let fallbackSessionID: String
    /// Confidence to attach to events from this profile. Process-observation
    /// profiles set this lower than hook-based ones.
    public let confidence: ConfidenceLevel

    public init(
        agentID: String,
        displayName: String,
        rules: [NormalizationRule],
        fallbackSessionID: String = "default",
        confidence: ConfidenceLevel = .high
    ) {
        self.agentID = agentID
        self.displayName = displayName
        self.rules = rules
        self.fallbackSessionID = fallbackSessionID
        self.confidence = confidence
    }
}

public enum NormalizationError: Error, Equatable, Sendable {
    case unknownEvent(String, agentID: String)
    case notJSON
}

public extension NormalizationRule {
    /// Whether this rule is the right one for an event, given its payload.
    func applies(to eventName: String, payload: [String: Any]) -> Bool {
        guard matches.contains(eventName) else { return false }

        if let required = whenNotificationType {
            let actual = payload["notification_type"] as? String
            guard actual == required else { return false }
        }

        if suppressedByRunningBackgroundTask,
           EventNormalizer.hasRunningBackgroundTask(payload) {
            return false
        }

        return true
    }
}

/// Turns a `BridgeEnvelope` into zero or more `AgentEvent`s.
public struct EventNormalizer: Sendable {
    private let profiles: [String: AgentProfile]

    public init(profiles: [AgentProfile]) {
        self.profiles = Dictionary(uniqueKeysWithValues: profiles.map { ($0.agentID, $0) })
    }

    public func profile(for agentID: String) -> AgentProfile? {
        profiles[agentID]
    }

    /// An envelope from an unknown agent, or naming an event no rule covers,
    /// yields an empty array. Unrecognised input is not an error worth
    /// crashing over — a newer agent version may simply have added an event.
    public func normalize(_ envelope: BridgeEnvelope) -> [AgentEvent] {
        guard let profile = profiles[envelope.agentID] else { return [] }

        let payload = Self.parseObject(envelope.rawPayload)
        guard let rule = profile.rules.first(where: {
            $0.applies(to: envelope.eventName, payload: payload)
        }) else {
            return []
        }

        let sessionID = Self.string(payload, rule.sessionIDField)
            ?? Self.fallbackSessionID(for: envelope, profile: profile)
        let summary = Self.string(payload, rule.summaryField)
        let detail = Self.string(payload, rule.detailField)
            .flatMap { PetNotification.preview(of: $0) }
        let cwd = Self.string(payload, rule.workingDirectoryField)

        var focus: FocusTarget = .unavailable
        if let cwd, !cwd.isEmpty {
            focus = .openingDirectory(URL(fileURLWithPath: cwd))
        }

        return [AgentEvent(
            agentID: envelope.agentID,
            sessionID: sessionID,
            kind: rule.kind,
            at: envelope.receivedAt,
            confidence: EventConfidence(
                level: profile.confidence,
                source: "\(envelope.agentID).hook.\(envelope.eventName)"
            ),
            summary: summary,
            detail: detail,
            projectPath: cwd.map { URL(fileURLWithPath: $0) },
            focusTarget: focus
        )]
    }

    /// Whether the payload lists a background task that has not finished.
    ///
    /// Claude Code's `Stop` fires whenever the main agent yields, which it does
    /// while a background subagent is still working. Without this check every
    /// long job is announced as complete the moment the agent first pauses.
    static func hasRunningBackgroundTask(_ payload: [String: Any]) -> Bool {
        guard let tasks = payload["background_tasks"] as? [[String: Any]] else { return false }
        return tasks.contains { task in
            (task["status"] as? String)?.lowercased() == "running"
        }
    }

    /// What to call a session when the payload does not name one.
    ///
    /// The shim's parent process is the agent, so its pid distinguishes
    /// concurrent sessions of the same agent. Falling back to a constant would
    /// merge every session into one indistinguishable activity, which is worse
    /// than a slightly awkward name.
    static func fallbackSessionID(for envelope: BridgeEnvelope, profile: AgentProfile) -> String {
        if let ppid = envelope.proc?.ppid, ppid > 0 {
            return "ppid-\(ppid)"
        }
        return profile.fallbackSessionID
    }

    /// The payload is parsed leniently and only for a few top-level keys. A
    /// payload that is not JSON at all is legitimate — some hooks pass plain
    /// text — and must not fail the event.
    static func parseObject(_ data: Data) -> [String: Any] {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    static func string(_ payload: [String: Any], _ key: String?) -> String? {
        guard let key, let value = payload[key] else { return nil }
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
