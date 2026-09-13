import AgentPetCore
import AppKit

/// Draws the current sprite frame, the message beside it, and handles dragging.
///
/// Deliberately dumb: it knows how to put one `CGImage` on screen, how to draw
/// a short message above it, and how to be dragged. All decisions about *which*
/// frame and *which* message belong on screen live in `AgentPetCore`, so the
/// preview in a manager window and the desktop pet cannot drift apart.
final class PetView: NSView {

    private var image: CGImage?
    private var notification: PetNotification?

    /// Height reserved above the sprite when a message is showing.
    ///
    /// Codex reserves one terminal row for a message whose two lines are the
    /// same and two rows otherwise; at desktop scale that is one or two lines
    /// of text plus padding.
    static let messageLineHeight: CGFloat = 15
    static let messagePadding: CGFloat = 6
    /// Room for the little tail that points at the pet.
    static let messageTailHeight: CGFloat = 4

    /// How tall the message area must be for a given notification.
    static func messageHeight(for notification: PetNotification?) -> CGFloat {
        guard let notification else { return 0 }
        let lines: CGFloat = notification.showsDetail ? 2 : 1
        return lines * messageLineHeight + messagePadding * 2 + messageTailHeight
    }

    /// The part of the view the sprite occupies. The message, when present,
    /// takes the strip above it, so the pet itself never moves — the window
    /// grows upward instead.
    var spriteRect: CGRect {
        let inset = Self.messageHeight(for: notification)
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

    /// Sets the message drawn above the pet. The window height follows from
    /// this, so the owner is told when it changes.
    func show(_ notification: PetNotification?) {
        guard notification != self.notification else { return }
        self.notification = notification
        needsDisplay = true
    }

    /// What is currently set to be drawn. Read by the render self-test.
    var currentImage: CGImage? { image }
    var currentNotification: PetNotification? { notification }

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

        if let notification {
            drawMessage(notification, spriteRect: sprite, in: context)
        }
    }

    // MARK: - Message

    /// Draws the status line and, when it says something the label does not,
    /// the detail beneath it — the same shape Codex gives its notification.
    private func drawMessage(
        _ notification: PetNotification,
        spriteRect: CGRect,
        in context: CGContext
    ) {
        let height = Self.messageHeight(for: notification)
        let area = CGRect(
            x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height
        )
        let bubble = area.insetBy(dx: 2, dy: 0)
        let bodyRect = CGRect(
            x: bubble.minX, y: bubble.minY,
            width: bubble.width, height: bubble.height - Self.messageTailHeight
        )

        // A tail centred on the pet, pointing down at it.
        let tailWidth: CGFloat = 10
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: spriteRect.midX - tailWidth / 2, y: bubble.minY + Self.messageTailHeight))
        tail.addLine(to: CGPoint(x: spriteRect.midX, y: bubble.minY))
        tail.addLine(to: CGPoint(x: spriteRect.midX + tailWidth / 2, y: bubble.minY + Self.messageTailHeight))

        let shape = CGMutablePath()
        shape.addRoundedRect(
            in: bodyRect, cornerWidth: 6, cornerHeight: 6
        )
        shape.addPath(tail)

        context.saveGState()
        context.addPath(shape)
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.94).cgColor)
        context.fillPath()

        context.addPath(shape)
        context.setStrokeColor(NSColor.separatorColor.cgColor)
        context.setLineWidth(1)
        context.strokePath()
        context.restoreGState()

        let textArea = bodyRect.insetBy(dx: 6, dy: Self.messagePadding - 2)
        let label = Self.messageText(
            notification.kind.label,
            font: .systemFont(ofSize: 10, weight: .semibold),
            color: .labelColor
        )
        if notification.showsDetail {
            let rows = textArea.height / 2
            let labelRect = CGRect(
                x: textArea.minX, y: textArea.maxY - rows, width: textArea.width, height: rows
            )
            let detailRect = CGRect(
                x: textArea.minX, y: textArea.minY, width: textArea.width, height: rows
            )
            label.draw(in: labelRect)
            Self.messageText(
                notification.body,
                font: .systemFont(ofSize: 9),
                color: .secondaryLabelColor
            ).draw(in: detailRect)
        } else {
            label.draw(in: textArea)
        }
    }

    private static func messageText(
        _ string: String,
        font: NSFont,
        color: NSColor
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
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
