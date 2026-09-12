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
    /// Fires when the pet is picked up, so it can switch to locomotion.
    var onDragBegan: (() -> Void)?
    /// A click that was not a drag — the pet's cue to greet.
    var onClick: (() -> Void)?
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
    /// steals clicks meant for whatever is behind it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Before the first frame arrives there is nothing to grab, so the
        // window passes clicks straight through.
        guard let image else { return nil }
        let drawn = Self.fittedRect(
            imageSize: CGSize(width: image.width, height: image.height),
            in: bounds
        )
        // A small margin so the pet is not fiddly to grab.
        return drawn.insetBy(dx: -4, dy: -4).contains(point) ? self : nil
    }

    func show(_ image: CGImage?) {
        guard self.image !== image else { return }
        self.image = image
        needsDisplay = true
    }

    /// What is currently set to be drawn. Read by the render self-test.
    var currentImage: CGImage? { image }

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

    override func mouseDown(with event: NSEvent) {
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
