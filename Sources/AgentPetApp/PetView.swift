import AgentPetCore
import AppKit

/// Draws the current sprite frame and handles dragging.
///
/// Deliberately dumb: it knows how to put one `CGImage` on screen and how to
/// be dragged. All decisions about *which* frame belongs on screen live in
/// `AgentPetCore`, so the preview in a manager window and the desktop pet
/// cannot drift apart.
final class PetView: NSView {

    private var image: CGImage?

    /// Set by the controller so a drag can move the window rather than the view.
    var onDrag: ((NSPoint) -> Void)?

    private var dragOrigin: NSPoint?

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    /// The window is click-through until the pointer is actually over the pet,
    /// so the panel never steals clicks meant for whatever is behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let image else { return nil }
        let drawn = Self.fittedRect(
            imageSize: CGSize(width: image.width, height: image.height),
            in: bounds
        )
        // Allow a small margin so the pet is not fiddly to grab.
        return drawn.insetBy(dx: -4, dy: -4).contains(point) ? self : nil
    }

    func show(_ image: CGImage?) {
        guard self.image !== image else { return }
        self.image = image
        needsDisplay = true
    }

    /// What is currently set to be drawn. Read by the render self-test.
    var currentImage: CGImage? { image }

    /// Set to have the view report what it draws. Off by default: this fires
    /// sixty times a second.
    static var isLoggingFrames = false

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let context = NSGraphicsContext.current?.cgContext else { return }

        let target = Self.fittedRect(
            imageSize: CGSize(width: image.width, height: image.height),
            in: bounds
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
    }

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

    override func mouseDown(with event: NSEvent) {
        dragOrigin = event.locationInWindow
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragOrigin else { return }
        onDrag?(NSPoint(
            x: event.locationInWindow.x - dragOrigin.x,
            y: event.locationInWindow.y - dragOrigin.y
        ))
    }

    override func mouseUp(with event: NSEvent) {
        if dragOrigin == nil {
            // A click with no movement is a request for attention, not a drag.
            NSApp.activate(ignoringOtherApps: true)
        }
        dragOrigin = nil
    }
}
