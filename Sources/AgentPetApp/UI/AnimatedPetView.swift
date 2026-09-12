import AgentPetCore
import AppKit
import SwiftUI

/// An animated preview of one pet.
///
/// Drives `AnimationResolver` — the same resolver the desktop pet uses. The
/// design calls this out specifically: a manager that previews with its own
/// playback code will eventually disagree with what the user actually sees.
struct AnimatedPetView: NSViewRepresentable {

    let sprite: SpriteFrames
    /// Which animation to show. Defaults to `idle`.
    var trackName: String = "idle"
    /// Frames per second to redraw at. Bounds smoothness only; frames are
    /// chosen by elapsed time.
    var refreshRate: Double = 30
    var isAnimating: Bool = true

    func makeNSView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.configure(sprite: sprite, trackName: trackName,
                       refreshRate: refreshRate, isAnimating: isAnimating)
        return view
    }

    func updateNSView(_ view: PreviewSurface, context: Context) {
        view.configure(sprite: sprite, trackName: trackName,
                       refreshRate: refreshRate, isAnimating: isAnimating)
    }

    static func dismantleNSView(_ view: PreviewSurface, coordinator: ()) {
        view.stop()
    }

    /// Minimal drawing surface: one frame, chosen by the shared resolver.
    final class PreviewSurface: NSView {
        private var sprite: SpriteFrames?
        private var track: AnimationTrack?
        private var timer: Timer?
        private var startedAt = Date()
        private let resolver = AnimationResolver()

        override var isOpaque: Bool { false }

        func configure(sprite: SpriteFrames, trackName: String, refreshRate: Double, isAnimating: Bool) {
            let trackChanged = self.track?.name != trackName
            self.sprite = sprite
            self.track = sprite.profile.track(named: trackName)

            if trackChanged {
                startedAt = Date()
                needsDisplay = true
            }

            if isAnimating {
                start(refreshRate: refreshRate)
            } else {
                stop()
                needsDisplay = true
            }
        }

        private func start(refreshRate: Double) {
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 1.0 / max(1, refreshRate), repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
            // `.common` keeps previews animating while a menu or drag is active.
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let sprite, let track,
                  let context = NSGraphicsContext.current?.cgContext else { return }

            let frame = resolver.frame(
                for: track, elapsed: Date().timeIntervalSince(startedAt)
            )
            guard let image = sprite.image(for: frame) else { return }

            let target = Self.fitted(
                CGSize(width: image.width, height: image.height), in: bounds
            )
            context.saveGState()
            context.interpolationQuality = .none
            context.draw(image, in: target)
            context.restoreGState()
        }

        /// Aspect-fit without distortion, so a 192x208 cell never stretches to
        /// a differently-shaped preview pane.
        static func fitted(_ size: CGSize, in bounds: CGRect) -> CGRect {
            guard size.width > 0, size.height > 0 else { return bounds }
            let scale = min(bounds.width / size.width, bounds.height / size.height)
            let scaled = CGSize(width: size.width * scale, height: size.height * scale)
            return CGRect(
                x: bounds.midX - scaled.width / 2,
                y: bounds.midY - scaled.height / 2,
                width: scaled.width, height: scaled.height
            )
        }
    }
}
