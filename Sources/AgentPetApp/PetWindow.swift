import AgentPetCore
import AppKit

/// The floating desktop pet surface.
///
/// The style mask matters more than it looks. `.nonactivatingPanel` is what
/// keeps the pet from stealing focus from whatever the user is typing in —
/// a pet that takes key focus when clicked would interrupt the very agent
/// session it is reporting on.
final class PetWindow: NSPanel {

    /// The window a pet of this width is drawn in. The sprite fills it, so the
    /// window *is* the pet's size.
    nonisolated static func size(forWidth width: CGFloat) -> NSSize {
        NSSize(width: width, height: CGFloat(AppConfig.PetConfig.height(forWidth: Double(width))))
    }

    /// Codex's own size — its `avatar-overlay-mascot-width-px` defaults to
    /// 112, which is the width of the sprite this project draws.
    nonisolated static var defaultSize: NSSize {
        size(forWidth: CGFloat(AppConfig.PetConfig.defaultWidth))
    }

    /// Where the pet appears the first time it is run.
    ///
    /// Deliberately the *primary* display rather than `NSScreen.main`. The
    /// latter follows keyboard focus and can be a secondary display positioned
    /// at a negative origin, which puts a first-run pet somewhere the user is
    /// not looking. Once the user drags it, the saved position wins.
    nonisolated static func defaultOrigin(on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        return NSPoint(
            x: visible.maxX - defaultSize.width - 32,
            y: visible.minY + 32
        )
    }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        level = .floating
        // `.canJoinAllSpaces` keeps the pet visible while switching desktops;
        // `.fullScreenAuxiliary` lets it float over a full-screen app.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
    }

    /// A borderless window refuses key status by default, which would stop the
    /// pet responding to clicks.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
