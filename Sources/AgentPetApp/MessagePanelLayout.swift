import AgentPetCore
import AppKit

/// Turns a `MessagePanel` into rectangles.
///
/// Kept apart from drawing and from the window, because three callers need the
/// same answers: the view draws them, the window sizes itself from them, and
/// the self-test measures them. One layout, computed the same way each time.
///
/// Main-actor because it holds fonts and a colour, and AppKit types are not
/// `Sendable`; every caller draws on the main thread anyway.
@MainActor
enum MessagePanelLayout {

    nonisolated static let rowHeight: CGFloat = 15
    nonisolated static let rowSpacing: CGFloat = 2
    nonisolated static let padding: CGFloat = 8
    nonisolated static let spacing: CGFloat = 8
    nonisolated static let tailHeight: CGFloat = 4
    /// Beyond this the panel would be a window of its own. Rows truncate
    /// instead; the pet is what is being looked at, and the panel is beside it.
    nonisolated static let maximumWidth: CGFloat = 520
    /// Narrower than this and an item says nothing useful.
    nonisolated static let minimumItemWidth: CGFloat = 34
    nonisolated static let contextBarSize = CGSize(width: 46, height: 6)

    /// Fluorescent green, the one colour in the panel that is not a system
    /// colour: how full a context window is has to be readable at a glance
    /// from across the room, on any desktop picture.
    static let usageColor = NSColor(srgbRed: 57 / 255, green: 255 / 255, blue: 20 / 255, alpha: 1)

    static let agentFont = NSFont.systemFont(ofSize: 10, weight: .semibold)
    static let itemFont = NSFont.systemFont(ofSize: 9)
    static let sessionFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .regular)
    static let messageFont = NSFont.systemFont(ofSize: 9, weight: .semibold)

    struct Item {
        let kind: MessagePanelConfig.Kind
        let primary: String
        let secondary: String?
        let context: SessionContext?
        let width: CGFloat
        let isFlexible: Bool
    }

    struct Row {
        let id: String
        let isFocused: Bool
        let items: [Item]
    }

    struct Plan {
        let rows: [Row]
        /// How wide the panel would like to be, before the window caps it.
        let desiredWidth: CGFloat

        var height: CGFloat {
            guard !rows.isEmpty else { return 0 }
            return CGFloat(rows.count) * rowHeight
                + CGFloat(rows.count - 1) * rowSpacing
                + padding * 2 + tailHeight
        }
    }

    // MARK: - Items

    /// The items one row would draw, in configured order.
    ///
    /// Content that does not exist is left out rather than drawn as a blank:
    /// a session with no status line has no context figure, and an empty bar
    /// would read as a full one at a glance.
    static func items(for row: MessagePanel.Row, config: MessagePanelConfig) -> [Item] {
        config.items.compactMap { item in
            guard item.isEnabled else { return nil }
            switch item.kind {
            case .agent:
                return Item(kind: .agent, primary: row.agentName, secondary: nil,
                            context: nil, width: width(of: row.agentName, font: agentFont),
                            isFlexible: false)
            case .session:
                return Item(kind: .session, primary: row.sessionSuffix, secondary: nil,
                            context: nil, width: width(of: row.sessionSuffix, font: sessionFont),
                            isFlexible: false)
            case .task:
                guard let task = row.task else { return nil }
                return Item(kind: .task, primary: task, secondary: nil, context: nil,
                            width: min(width(of: task, font: itemFont), 180), isFlexible: true)
            case .tool:
                guard let tool = row.tool else { return nil }
                return Item(kind: .tool, primary: tool, secondary: nil, context: nil,
                            width: min(width(of: tool, font: itemFont), 120), isFlexible: false)
            case .context:
                guard let context = row.context, let label = usageLabel(context) else { return nil }
                let hasBar = usageFraction(context) != nil
                let barAndGap: CGFloat = hasBar ? contextBarSize.width + 5 : 0
                return Item(kind: .context, primary: label, secondary: nil, context: context,
                            width: barAndGap + width(of: label, font: itemFont), isFlexible: false)
            case .message:
                guard let message = row.message else { return nil }
                let full = message.body.map { "\(message.label) — \($0)" } ?? message.label
                return Item(kind: .message, primary: message.label, secondary: message.body,
                            context: nil, width: min(width(of: full, font: messageFont), 260),
                            isFlexible: true)
            }
        }
    }

    /// The percentage to show, or a token count when a percentage cannot be
    /// worked out honestly.
    static func usageLabel(_ context: SessionContext) -> String? {
        if let percent = usageFraction(context) {
            return "\(Int((percent * 100).rounded()))%"
        }
        if let tokens = context.totalTokens { return compact(tokens) }
        return nil
    }

    /// Used fraction, 0...1, or nil when it is not knowable.
    ///
    /// Claude Code's own number is preferred — it knows the window size for
    /// whatever model the gateway is actually serving. The fallback computes
    /// from tokens only when a window size came along, because dividing by a
    /// window we guessed would be a number that looks authoritative and is not.
    static func usageFraction(_ context: SessionContext) -> Double? {
        if let percent = context.usedPercent {
            return min(max(percent / 100, 0), 1)
        }
        guard let tokens = context.totalTokens, let window = context.windowSize, window > 0 else {
            return nil
        }
        return min(max(Double(tokens) / Double(window), 0), 1)
    }

    static func compact(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            return String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
        if tokens >= 1_000 {
            return "\(tokens / 1_000)k"
        }
        return "\(tokens)"
    }

    // MARK: - Rows

    static func plan(for panel: MessagePanel, config: MessagePanelConfig) -> Plan {
        let rows = panel.rows.map { row in
            Row(id: row.id, isFocused: row.isFocused, items: items(for: row, config: config))
        }.filter { !$0.items.isEmpty }

        let desired = rows.map(rowWidth).max() ?? 0
        return Plan(rows: rows, desiredWidth: desired + padding * 2)
    }

    private static func rowWidth(_ row: Row) -> CGFloat {
        row.items.map(\.width).reduce(0, +)
            + spacing * CGFloat(max(0, row.items.count - 1))
    }

    /// Lay one row out inside `width`, shrinking the flexible items first and
    /// everything else after that.
    ///
    /// Rectangles are returned in order; nothing is dropped silently except
    /// items squeezed below the width at which they would say anything.
    static func frames(for row: Row, in width: CGFloat) -> [(item: Item, frame: CGRect)] {
        let available = width - padding * 2
        let gaps = spacing * CGFloat(max(0, row.items.count - 1))
        var budget = max(0, available - gaps)

        let natural = row.items.map(\.width).reduce(0, +)
        var widths = row.items.map(\.width)

        if natural > budget {
            // Take it out of the flexible items first — a task name squeezed
            // is a smaller loss than a session id cut in half.
            var deficit = natural - budget
            let flexibleIndices = row.items.indices.filter { row.items[$0].isFlexible }
            for index in flexibleIndices where deficit > 0 {
                let room = max(0, widths[index] - minimumItemWidth)
                let take = min(room, deficit)
                widths[index] -= take
                deficit -= take
            }
            if deficit > 0 {
                for index in row.items.indices where deficit > 0 {
                    let room = max(0, widths[index] - minimumItemWidth / 2)
                    let take = min(room, deficit)
                    widths[index] -= take
                    deficit -= take
                }
            }
        }

        var frames: [(item: Item, frame: CGRect)] = []
        var x = padding
        for (index, item) in row.items.enumerated() {
            let itemWidth = widths[index]
            guard itemWidth >= minimumItemWidth / 2 else { continue }
            frames.append((item, CGRect(x: x, y: 0, width: itemWidth, height: rowHeight)))
            x += itemWidth + spacing
        }
        return frames
    }

    /// How big the window needs to be for this panel.
    ///
    /// Width is capped and height is not: a panel two rows deep is worth a
    /// wider window, and one ten rows deep is not worth a wider window *or* a
    /// panel that runs off the screen — height is bounded by how many sessions
    /// a person runs, which is a number they choose.
    static func desiredSize(for panel: MessagePanel, config: MessagePanelConfig) -> CGSize {
        let plan = plan(for: panel, config: config)
        return CGSize(
            width: min(plan.desiredWidth, maximumWidth),
            height: plan.height
        )
    }

    // MARK: - Measuring

    static func width(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }
}
