import Foundation

/// Which parts of a session's row are drawn beside the pet, and in what order.
///
/// The panel is a dashboard, and a dashboard that cannot be edited is one the
/// user lives with rather than uses: some people want the context bar and
/// nothing else, some want only the sessions that need them.
public struct MessagePanelConfig: Codable, Sendable, Equatable {

    /// How wide the panel may be, as a percentage of the pet's own width.
    ///
    /// A percentage rather than points because the pet is what it sits beside:
    /// 200% is "twice the pet", whatever size that pet draws at.
    public static let minimumWidthPercent: Double = 100
    public static let maximumWidthPercent: Double = 200

    /// Whether the panel stays up while sessions are idle, or only appears
    /// when something is actually happening.
    public var alwaysVisible: Bool
    /// Display order, left to right within a row.
    public var items: [Item]
    /// Panel width as a percentage of the pet's width, 100–200.
    public var widthPercent: Double
    /// Where the rows sit inside the panel.
    public var alignment: Alignment

    public init(
        alwaysVisible: Bool = true,
        items: [Item] = Kind.allCases.map { Item($0) },
        widthPercent: Double = MessagePanelConfig.maximumWidthPercent,
        alignment: Alignment = .left
    ) {
        self.alwaysVisible = alwaysVisible
        self.items = items
        self.widthPercent = widthPercent
        self.alignment = alignment
    }

    /// Decoded field by field, for the same reason `AppConfig` is: a config
    /// written by the previous release has no `widthPercent` and would fail
    /// the whole decode — and the stores refuse to half-read a file, so the
    /// user's panel would come back as defaults.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MessagePanelConfig()
        alwaysVisible = try container.decodeIfPresent(Bool.self, forKey: .alwaysVisible)
            ?? defaults.alwaysVisible
        widthPercent = Self.clampWidth(
            try container.decodeIfPresent(Double.self, forKey: .widthPercent) ?? defaults.widthPercent
        )
        alignment = try container.decodeIfPresent(Alignment.self, forKey: .alignment)
            ?? defaults.alignment

        var decoded = try container.decodeIfPresent([Item].self, forKey: .items) ?? defaults.items
        // A kind this config has never heard of — one added since it was
        // written — joins the end of the list rather than being invisible.
        // The manager has no way to *remove* an item, only to switch it off,
        // so an absent kind means "older file", not "user's choice".
        for kind in Kind.allCases where !decoded.contains(where: { $0.kind == kind }) {
            decoded.append(Item(kind))
        }
        items = decoded
    }

    public static func clampWidth(_ percent: Double) -> Double {
        min(max(percent, minimumWidthPercent), maximumWidthPercent)
    }

    public enum Alignment: String, Codable, Sendable, CaseIterable, Identifiable {
        case left
        case center
        case right

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .left:   return "Left"
            case .center: return "Centre"
            case .right:  return "Right"
            }
        }
    }

    public struct Item: Codable, Sendable, Equatable, Identifiable {
        public var kind: Kind
        public var isEnabled: Bool

        public init(_ kind: Kind, isEnabled: Bool = true) {
            self.kind = kind
            self.isEnabled = isEnabled
        }

        public var id: String { kind.rawValue }
    }

    public enum Kind: String, Codable, Sendable, CaseIterable, Identifiable {
        case agent
        case session
        case task
        case model
        case tool
        case context
        case cost
        case limits
        case message

        public var id: String { rawValue }

        /// What the manager calls it.
        public var title: String {
            switch self {
            case .agent:   return "Agent"
            case .session: return "Session"
            case .task:    return "Task"
            case .model:   return "Model"
            case .tool:    return "Current tool"
            case .context: return "Context used"
            case .cost:    return "Session cost"
            case .limits:  return "Rate limits"
            case .message: return "Status message"
            }
        }

        public var explanation: String {
            switch self {
            case .agent:   return "Which agent the session belongs to."
            case .session: return "The last six characters of the session id."
            case .task:    return "The session's name, or its repository or project directory."
            case .model:   return "The model serving the session, and its reasoning effort."
            case .tool:    return "The tool the session is using, while it is working."
            case .context: return "How full the session's context window is. Needs the status line tap."
            case .cost:    return "Estimated session cost, as Claude Code reports it."
            case .limits:  return "How much of the 5-hour and 7-day usage windows is gone. Needs the status line tap."
            case .message: return "The same wording the pet has always used: Running, Needs input, Ready, Blocked."
            }
        }

        /// Items only a status-line tap can fill.
        public var needsStatusLine: Bool {
            switch self {
            case .context, .cost, .limits, .model: return true
            case .agent, .session, .task, .tool, .message: return false
            }
        }
    }

    public static let defaults: [Item] = Kind.allCases.map { Item($0) }
}

/// The rows drawn above the pet: one per session, grouped by agent, best first.
public struct MessagePanel: Sendable, Equatable {

    public struct Row: Sendable, Equatable, Identifiable {
        /// The activity's id, so a row can be traced back to a session.
        public let id: String
        public let agentID: String
        public let agentName: String
        /// The last six characters of the session id — enough to tell two
        /// terminals apart, short enough to sit in a row.
        public let sessionSuffix: String
        /// Session name, else project, else the directory the session runs in.
        public let task: String?
        /// Only while the session is working: a tool it finished with is not
        /// the tool it is using.
        public let tool: String?
        public let context: SessionContext?
        public let message: Message?
        public let state: AgentState
        public let isFocused: Bool
    }

    /// The wording the pet has always shown, per session.
    public struct Message: Sendable, Equatable {
        public let label: String
        public let body: String?
        public var showsDetail: Bool { body != nil }
    }

    public var rows: [Row]

    public init(rows: [Row] = []) {
        self.rows = rows
    }

    public var isEmpty: Bool { rows.isEmpty }
    public static let empty = MessagePanel()

    /// How long a session that is doing nothing keeps its row.
    ///
    /// A session ends with `SessionEnd`, but a terminal that was closed, or
    /// killed, never sends one — and an idle row with no expiry would leave a
    /// stranger's session floating beside the pet forever. Ten minutes is long
    /// enough to come back to a terminal and still find its row.
    public static let idleRowLifetime: TimeInterval = 600

    /// Builds the panel from the engine's ranked sessions.
    ///
    /// Pure: everything it needs is passed in, so the manager's preview, the
    /// desktop pet, and the tests all build the same rows from the same facts.
    public static func build(
        ranked: [AgentActivity],
        focusedID: String?,
        agentNames: [String: String] = [:],
        config: MessagePanelConfig,
        now: Date
    ) -> MessagePanel {
        let visible = ranked.filter { isVisible($0, now: now) }
        guard !visible.isEmpty else { return .empty }

        // A panel that is only there when something is happening is a panel
        // the user asked not to babysit.
        if !config.alwaysVisible, !visible.contains(where: { $0.state != .idle }) {
            return .empty
        }

        // Same agent's sessions together, groups in the order their best
        // session ranks, sessions within a group keeping that ranking.
        var agentOrder: [String] = []
        var byAgent: [String: [AgentActivity]] = [:]
        for activity in visible {
            if byAgent[activity.agentID] == nil { agentOrder.append(activity.agentID) }
            byAgent[activity.agentID, default: []].append(activity)
        }

        let rows = agentOrder.flatMap { agentID in
            (byAgent[agentID] ?? []).map { activity in
                row(for: activity, focusedID: focusedID, agentNames: agentNames)
            }
        }
        return MessagePanel(rows: rows)
    }

    private static func isVisible(_ activity: AgentActivity, now: Date) -> Bool {
        guard activity.state == .idle else { return true }
        // Nothing is waiting on an idle session, so its row is only there to
        // say "this one exists" — and only while it plausibly still does.
        return now.timeIntervalSince(activity.lastHeardAt) < idleRowLifetime
    }

    private static func row(
        for activity: AgentActivity,
        focusedID: String?,
        agentNames: [String: String]
    ) -> Row {
        Row(
            id: activity.id,
            agentID: activity.agentID,
            agentName: agentNames[activity.agentID] ?? activity.agentID,
            sessionSuffix: suffix(of: activity.sessionID),
            task: taskTitle(for: activity),
            tool: activity.state == .running ? activity.toolName : nil,
            context: activity.context,
            message: message(for: activity),
            state: activity.state,
            isFocused: activity.id == focusedID
        )
    }

    /// The last six characters, which is what distinguishes two sessions of
    /// the same agent at a glance.
    static func suffix(of sessionID: String) -> String {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.suffix(6))
    }

    /// Best available answer to "what is this session working on", in order of
    /// how much the user chose it: the name they gave the session, the
    /// repository, then the directory it runs in.
    static func taskTitle(for activity: AgentActivity) -> String? {
        if let name = activity.context?.sessionName { return name }
        if let project = activity.context?.projectName { return project }
        if let path = activity.focusTarget?.path, !path.isEmpty {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return nil
    }

    /// The per-session version of the message the pet already shows.
    ///
    /// Bodies follow the same rule as the focused message: a finished turn may
    /// show what the assistant said, because the user approved that trade —
    /// a working one shows nothing, because its summary is the user's prompt.
    static func message(for activity: AgentActivity) -> Message? {
        guard let kind = PetNotificationKind.forState(activity.state) else { return nil }
        let body: String?
        switch kind {
        case .waiting, .failed: body = activity.title
        case .review:           body = activity.detail
        case .running:          body = nil
        }
        return Message(label: kind.label, body: body)
    }
}
