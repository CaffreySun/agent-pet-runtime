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

    nonisolated static let rowHeight: CGFloat = 18
    nonisolated static let rowSpacing: CGFloat = 2
    nonisolated static let padding: CGFloat = 9
    nonisolated static let spacing: CGFloat = 8
    nonisolated static let tailHeight: CGFloat = 4
    /// Narrower than this and an item says nothing useful.
    nonisolated static let minimumItemWidth: CGFloat = 34
    nonisolated static let contextBarSize = CGSize(width: 46, height: 7)

    /// Fluorescent green, the one colour in the panel that is not a system
    /// colour: how full a context window is has to be readable at a glance
    /// from across the room, on any desktop picture.
    static let usageColor = NSColor(srgbRed: 57 / 255, green: 255 / 255, blue: 20 / 255, alpha: 1)

    static let agentFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let itemFont = NSFont.systemFont(ofSize: 10.5)
    static let sessionFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
    static let messageFont = NSFont.systemFont(ofSize: 10.5, weight: .semibold)

    /// The panel's width, in points, for a configuration and a pet.
    ///
    /// A percentage of the pet's own width, clamped to the range the settings
    /// allow, so "200%" means twice the pet at whatever size the pet is drawn.
    static func panelWidth(for config: MessagePanelConfig, petWidth: CGFloat) -> CGFloat {
        (petWidth * CGFloat(MessagePanelConfig.clampWidth(config.widthPercent)) / 100)
            .rounded()
    }

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
        /// Panel-wide, carried per row so `frames` needs nothing else.
        let alignment: MessagePanelConfig.Alignment
        let items: [Item]
    }

    struct Plan {
        let rows: [Row]
        let alignment: MessagePanelConfig.Alignment

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
                            width: min(width(of: task, font: itemFont), 200), isFlexible: true)
            case .model:
                guard let context = row.context, let label = context.modelLabel else { return nil }
                return Item(kind: .model, primary: label, secondary: nil, context: context,
                            width: min(width(of: label, font: itemFont), 160), isFlexible: false)
            case .tool:
                guard let tool = row.tool else { return nil }
                return Item(kind: .tool, primary: tool, secondary: nil, context: nil,
                            width: min(width(of: tool, font: itemFont), 130), isFlexible: false)
            case .context:
                guard let context = row.context, let label = usageLabel(context) else { return nil }
                let hasBar = usageFraction(context) != nil
                let barAndGap: CGFloat = hasBar ? contextBarSize.width + 5 : 0
                return Item(kind: .context, primary: label, secondary: nil, context: context,
                            width: barAndGap + width(of: label, font: itemFont), isFlexible: false)
            case .cost:
                guard let label = row.context?.costLabel else { return nil }
                return Item(kind: .cost, primary: label, secondary: nil, context: row.context,
                            width: width(of: label, font: itemFont), isFlexible: false)
            case .limits:
                guard let limits = row.context?.limitsLabel else { return nil }
                return Item(kind: .limits, primary: limits, secondary: nil, context: row.context,
                            width: min(width(of: limits, font: itemFont), 200), isFlexible: false)
            case .message:
                guard let message = row.message else { return nil }
                let full = message.body.map { "\(message.label) — \($0)" } ?? message.label
                return Item(kind: .message, primary: message.label, secondary: message.body,
                            context: nil, width: min(width(of: full, font: messageFont), 300),
                            isFlexible: true)
            }
        }
    }

    /// The percentage to show, or a token count when a percentage cannot be
    /// worked out honestly.
    static func usageLabel(_ context: SessionContext) -> String? {
        if let fraction = usageFraction(context) {
            return "\(Int((fraction * 100).rounded()))%"
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

    /// The last layout built, kept for the next caller.
    ///
    /// `plan` is asked for on every frame — the window sizes itself from it
    /// sixty times a second — and building one measures the text of every item
    /// in every row. The panel and its configuration change on the scale of an
    /// event, not of a frame, so one remembered layout is enough to keep the
    /// frame loop out of text measurement entirely.
    private static var remembered: (panel: MessagePanel, config: MessagePanelConfig, plan: Plan)?

    static func plan(for panel: MessagePanel, config: MessagePanelConfig) -> Plan {
        if let remembered, remembered.panel == panel, remembered.config == config {
            return remembered.plan
        }
        let plan = build(panel, config)
        remembered = (panel, config, plan)
        return plan
    }

    private static func build(_ panel: MessagePanel, _ config: MessagePanelConfig) -> Plan {
        let rows = panel.rows.map { row in
            Row(id: row.id, isFocused: row.isFocused, alignment: config.alignment,
                items: items(for: row, config: config))
        }.filter { !$0.items.isEmpty }

        return Plan(rows: rows, alignment: config.alignment)
    }

    /// Lay one row out inside `width`, shrinking the flexible items first and
    /// everything else after that, then aligning the result.
    ///
    /// Rectangles are returned in order; nothing is dropped silently except
    /// items squeezed below the width at which they would say anything.
    static func frames(for row: Row, in width: CGFloat) -> [(item: Item, frame: CGRect)] {
        let available = width - padding * 2
        let gaps = spacing * CGFloat(max(0, row.items.count - 1))
        let budget = max(0, available - gaps)

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

        let drawn = widths.enumerated().filter { $0.element >= minimumItemWidth / 2 }
        let drawnWidth = drawn.map(\.element).reduce(0, +)
            + spacing * CGFloat(max(0, drawn.count - 1))

        // Where the rows sit within the panel: left, centred, or right. The
        // pet stays where it is either way — this is about the text.
        var x: CGFloat
        switch row.alignment {
        case .left:   x = padding
        case .center: x = max(padding, (width - drawnWidth) / 2)
        case .right:  x = max(padding, width - padding - drawnWidth)
        }

        var frames: [(item: Item, frame: CGRect)] = []
        for (index, item) in row.items.enumerated() where widths[index] >= minimumItemWidth / 2 {
            frames.append((item, CGRect(x: x, y: 0, width: widths[index], height: rowHeight)))
            x += widths[index] + spacing
        }
        return frames
    }

    // MARK: - Measuring

    static func width(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }
}
