import AgentPetCore
import AppKit

/// Draws the current sprite frame, the session panel above it, and handles
/// dragging.
///
/// Deliberately dumb: it knows how to put one `CGImage` on screen, how to draw
/// a row of short labels above it, and how to be dragged. All decisions about
/// *which* frame and *which* rows belong on screen live in `AgentPetCore`, so
/// the preview in a manager window and the desktop pet cannot drift apart.
final class PetView: NSView {

    private var image: CGImage?
    private var panel: MessagePanel = .empty
    private var panelConfig = MessagePanelConfig()

    /// How tall the panel strip must be for a panel.
    static func panelHeight(for panel: MessagePanel, config: MessagePanelConfig) -> CGFloat {
        MessagePanelLayout.plan(for: panel, config: config).height
    }

    /// The part of the view the sprite occupies. The panel, when present,
    /// takes the strip above it, so the pet itself never moves — the window
    /// grows upward (and, for a wide panel, sideways) instead.
    var spriteRect: CGRect {
        let inset = Self.panelHeight(for: panel, config: panelConfig)
        return CGRect(
            x: bounds.minX, y: bounds.minY,
            width: bounds.width, height: max(0, bounds.height - inset)
        )
    }

    /// Set by the controller so a drag can move the window rather than the view.
    var onDrag: ((NSPoint) -> Void)?
    /// Fires when the pet is picked up, so it can switch to locomotion.
    var onDragBegan: (() -> Void)?
    /// A click that was not a drag — the pet's cue to greet.
    var onClick: (() -> Void)?
    /// Double-clicking the pet opens the manager.
    var onDoubleClick: (() -> Void)?
    /// Right-clicking the pet raises the same menu as the status item.
    ///
    /// The pet is the thing the user is looking at, so it is where they will
    /// reach for the controls. Hunting for a menu bar icon is a needless step.
    var onRightClick: ((NSEvent) -> Void)?
    /// Called once a drag finishes, so the position can be persisted then
    /// rather than only at quit — a crash would otherwise lose it.
    var onDragEnded: (() -> Void)?

    /// The pointer arrived on the pet, or left it.
    ///
    /// Codex's pet plays its `jumping` row for this and holds the landing pose
    /// until the pointer goes, so the two events are not the same as a click.
    var onHoverBegan: (() -> Void)?
    var onHoverEnded: (() -> Void)?

    /// Tracks the sprite only. Tracking the whole view would make the pet jump
    /// when the pointer crossed the message panel above it.
    private var hoverTracking: NSTrackingArea?

    /// Distance from the window's origin to the mouse when the drag began,
    /// in screen coordinates.
    private var grabOffset: NSPoint?
    private var didMove = false

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// **Required, and the reason the pet could not be dragged.**
    ///
    /// The app runs as an accessory, so it is essentially never the active
    /// application. AppKit's default is to deliver the first click in an
    /// inactive window to the window itself for activation and *not* to the
    /// view — which is exactly right for most windows and completely wrong for
    /// a desktop pet, which the user clicks precisely because they are working
    /// somewhere else.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The window is click-through except over the pet itself, so it never
    /// steals clicks meant for whatever is behind it. The message is not
    /// grabbable: dragging the pet is how it is moved, and a panel that moved
    /// when someone tried to click its text would be a surprise.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Before the first frame arrives there is nothing to grab, so the
        // window passes clicks straight through.
        guard let image else { return nil }
        let drawn = Self.fittedRect(
            imageSize: CGSize(width: image.width, height: image.height),
            in: spriteRect
        )
        // A small margin so the pet is not fiddly to grab.
        return drawn.insetBy(dx: -4, dy: -4).contains(point) ? self : nil
    }

    func show(_ image: CGImage?) {
        guard self.image !== image else { return }
        self.image = image
        needsDisplay = true
    }

    /// Sets the panel drawn above the pet. The window size follows from this,
    /// so the owner is told when it changes.
    func show(_ panel: MessagePanel, config: MessagePanelConfig) {
        guard panel != self.panel || config != self.panelConfig else { return }
        self.panel = panel
        self.panelConfig = config
        needsDisplay = true
        // The sprite moved: the pointer's idea of where the pet is has to move
        // with it, or a panel appearing under the cursor would leave the pet
        // thinking it is still being hovered.
        updateTrackingAreas()
    }

    // MARK: - Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: spriteRect,
            // `.activeAlways`: the app is an accessory and its pet is almost
            // never in a key window, which is exactly the case `.activeInKeyWindow`
            // would drop.
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverBegan?()
    }

    override func mouseExited(with event: NSEvent) {
        onHoverEnded?()
    }

    /// What is currently set to be drawn. Read by the render self-test.
    var currentImage: CGImage? { image }
    var currentPanel: MessagePanel { panel }
    var currentPanelConfig: MessagePanelConfig { panelConfig }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }

        let sprite = spriteRect
        let target = Self.fittedRect(
            imageSize: CGSize(width: image.width, height: image.height),
            in: sprite
        )

        if Self.isLoggingFrames {
            FileHandle.standardError.write(Data(
                "[pet] draw bounds=\(bounds) target=\(target) image=\(image.width)x\(image.height)\n".utf8
            ))
        }

        context.saveGState()
        // The decoded buffer is already premultiplied and top-left origin;
        // telling CoreGraphics to smooth it would soften the pixel art edges.
        context.interpolationQuality = .none
        context.draw(image, in: target)
        context.restoreGState()

        let plan = MessagePanelLayout.plan(for: panel, config: panelConfig)
        if !plan.rows.isEmpty {
            drawPanel(plan, spriteRect: sprite)
        }
    }

    // MARK: - Panel

    /// Draws the session rows in the strip above the pet.
    private func drawPanel(_ plan: MessagePanelLayout.Plan, spriteRect: CGRect) {
        let height = plan.height
        let area = CGRect(
            x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height
        )
        let bubble = area.insetBy(dx: 2, dy: 0)
        let bodyRect = CGRect(
            x: bubble.minX, y: bubble.minY,
            width: bubble.width, height: bubble.height - MessagePanelLayout.tailHeight
        )

        // A tail centred on the pet, pointing down at it.
        let tailWidth: CGFloat = 10
        let tail = CGMutablePath()
        tail.move(to: CGPoint(
            x: spriteRect.midX - tailWidth / 2,
            y: bubble.minY + MessagePanelLayout.tailHeight
        ))
        tail.addLine(to: CGPoint(x: spriteRect.midX, y: bubble.minY))
        tail.addLine(to: CGPoint(
            x: spriteRect.midX + tailWidth / 2,
            y: bubble.minY + MessagePanelLayout.tailHeight
        ))

        let shape = CGMutablePath()
        shape.addRoundedRect(in: bodyRect, cornerWidth: 6, cornerHeight: 6)
        shape.addPath(tail)

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.addPath(shape)
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor)
        context.fillPath()
        context.addPath(shape)
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        // Rows run downward from the top of the bubble.
        var rowTop = bodyRect.maxY - MessagePanelLayout.padding
        for row in plan.rows {
            let rowRect = CGRect(
                x: bodyRect.minX,
                y: rowTop - MessagePanelLayout.rowHeight,
                width: bodyRect.width,
                height: MessagePanelLayout.rowHeight
            )
            drawRow(row, in: rowRect)
            rowTop = rowRect.minY - MessagePanelLayout.rowSpacing
        }
    }

    private func drawRow(_ row: MessagePanelLayout.Row, in rowRect: CGRect) {
        for (item, frame) in MessagePanelLayout.frames(for: row, in: rowRect.width) {
            let rect = CGRect(
                x: rowRect.minX + frame.minX,
                y: rowRect.minY,
                width: frame.width,
                height: MessagePanelLayout.rowHeight
            )
            switch item.kind {
            case .context:
                drawContext(item, in: rect)
            case .message:
                drawMessage(item, in: rect, isFocused: row.isFocused)
            case .agent:
                if !drawSymbol(item, in: rect) {
                    Self.text(item.primary, font: MessagePanelLayout.agentFont)
                        .draw(in: rect.insetBy(dx: 0, dy: 2.5))
                }
            case .session:
                Self.text(item.primary, font: MessagePanelLayout.sessionFont,
                          color: .secondaryLabelColor)
                    .draw(in: rect.insetBy(dx: 0, dy: 3))
            default:
                Self.text(item.primary, font: MessagePanelLayout.itemFont,
                          color: .secondaryLabelColor)
                    .draw(in: rect.insetBy(dx: 0, dy: 3))
            }
        }
    }

    /// Draws an item's symbol, if it has one, centred in its column.
    ///
    /// Tinted by hand — the glyph is drawn, then filled through with the label
    /// colour using `.sourceAtop`, which paints only where the symbol is. SF
    /// Symbols arrive as template images, and a template drawn directly takes
    /// the context's fill colour only inside a control.
    private func drawSymbol(_ item: MessagePanelLayout.Item, in rect: CGRect) -> Bool {
        guard let name = item.symbolName,
              let symbol = NSImage(systemSymbolName: name, accessibilityDescription: item.primary)?
                  .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        else { return false }

        let size = symbol.size
        let target = CGRect(
            x: rect.midX - size.width / 2,
            y: rect.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let tinted = NSImage(size: size, flipped: false) { frame in
            symbol.draw(in: frame)
            NSColor.labelColor.set()
            frame.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: target)
        return true
    }

    /// The usage bar and its number.
    ///
    /// A bar rather than a ring: rows are one line tall, and a ring that small
    /// reads as a dot. The filled part is fluorescent green on purpose — it is
    /// the one number here that changes on its own and is worth noticing from
    /// across the room.
    private func drawContext(_ item: MessagePanelLayout.Item, in rect: CGRect) {
        var textOrigin = rect.minX
        if let context = item.context, let fraction = MessagePanelLayout.usageFraction(context) {
            let bar = CGRect(
                x: rect.minX,
                y: rect.midY - MessagePanelLayout.contextBarSize.height / 2,
                width: MessagePanelLayout.contextBarSize.width,
                height: MessagePanelLayout.contextBarSize.height
            )
            NSColor.separatorColor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).fill()

            let filled = CGRect(
                x: bar.minX, y: bar.minY,
                width: max(2, bar.width * CGFloat(fraction)), height: bar.height
            )
            MessagePanelLayout.usageColor.setFill()
            NSBezierPath(roundedRect: filled, xRadius: 3, yRadius: 3).fill()
            textOrigin = bar.maxX + 5
        }

        let textRect = CGRect(
            x: textOrigin, y: rect.minY,
            width: max(0, rect.maxX - textOrigin), height: rect.height
        )
        Self.text(item.primary, font: MessagePanelLayout.itemFont,
                  color: .secondaryLabelColor)
            .draw(in: textRect.insetBy(dx: 0, dy: 3))
    }

    /// The wording the pet has always used, now one row among several.
    private func drawMessage(
        _ item: MessagePanelLayout.Item,
        in rect: CGRect,
        isFocused: Bool
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let string = NSMutableAttributedString(
            string: item.primary,
            attributes: [
                .font: MessagePanelLayout.messageFont,
                .foregroundColor: isFocused ? NSColor.labelColor : NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
        if let body = item.secondary {
            string.append(NSAttributedString(
                string: " — \(body)",
                attributes: [
                    .font: MessagePanelLayout.itemFont,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        string.draw(in: rect.insetBy(dx: 0, dy: 2.5))
    }

    private static func text(
        _ string: String,
        font: NSFont,
        color: NSColor = .labelColor
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
    }

    /// Set to have the view report what it draws. Off by default: this fires
    /// sixty times a second.
    static var isLoggingFrames = false

    /// Aspect-fit the cell inside the view without distorting it. Cells are
    /// 192x208, so a view of a different shape must letterbox rather than
    /// stretch the pet.
    static func fittedRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    // MARK: - Dragging

    // The arithmetic lives in `WindowDrag`, where it is pure and tested. In
    // particular it uses screen coordinates: the window's own coordinate
    // system moves with the window, so differencing it during a drag feeds
    // each move back into the next calculation.

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?(event)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
            return
        }
        guard let window else { return }
        grabOffset = WindowDrag.grabOffset(
            mouse: NSEvent.mouseLocation,
            windowOrigin: window.frame.origin
        )
        didMove = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let grabOffset else { return }
        if !didMove {
            didMove = true
            // Announced on the first movement, not on mouse-down, so a click
            // that never moves is a greeting rather than a zero-length drag.
            onDragBegan?()
        }
        onDrag?(WindowDrag.origin(mouse: NSEvent.mouseLocation, grabOffset: grabOffset))
    }

    override func mouseUp(with event: NSEvent) {
        grabOffset = nil
        if didMove {
            onDragEnded?()
        } else {
            onClick?()
        }
        didMove = false
    }
}
