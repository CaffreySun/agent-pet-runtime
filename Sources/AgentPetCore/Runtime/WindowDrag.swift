import CoreGraphics
import Foundation

/// Geometry for dragging a floating window.
///
/// Pure, and separated from the view that uses it, because the arithmetic is
/// easy to get subtly wrong in ways that only show up as the window sliding
/// away from the cursor under a real drag.
public enum WindowDrag {

    /// Where the window should move to.
    ///
    /// Takes **screen** coordinates. Using window-relative coordinates looks
    /// equivalent and is not: the window's coordinate system moves with the
    /// window, so each drag event is measured against an origin that the
    /// previous event already changed. The result is a window that accelerates
    /// away from the pointer.
    public static func origin(mouse: CGPoint, grabOffset: CGPoint) -> CGPoint {
        CGPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y)
    }

    /// How far the cursor sits from the window's origin at the moment of the
    /// grab. Keeping this constant is what makes the window track the cursor
    /// exactly rather than snapping its corner to it.
    public static func grabOffset(mouse: CGPoint, windowOrigin: CGPoint) -> CGPoint {
        CGPoint(x: mouse.x - windowOrigin.x, y: mouse.y - windowOrigin.y)
    }

    /// A frame that keeps a window fully inside the union of the given screens.
    ///
    /// A pet dragged past the edge of the last display, or left there when a
    /// monitor is unplugged, is unreachable — there is no dock icon to click
    /// and no window list entry to select.
    public static func clamped(
        origin: CGPoint,
        size: CGSize,
        into screens: [CGRect],
        minimumVisible: CGFloat = 40
    ) -> CGPoint {
        guard !screens.isEmpty else { return origin }

        let union = screens.dropFirst().reduce(screens[0]) { $0.union($1) }

        // Allow the pet to hang off an edge, but never so far that a grabbable
        // part of it is off every screen.
        let minX = union.minX - size.width + minimumVisible
        let maxX = union.maxX - minimumVisible
        let minY = union.minY - size.height + minimumVisible
        let maxY = union.maxY - minimumVisible

        return CGPoint(
            x: min(max(origin.x, minX), maxX),
            y: min(max(origin.y, minY), maxY)
        )
    }

    /// Whether a saved position still lands on a display that is attached.
    public static func isReachable(
        origin: CGPoint,
        size: CGSize,
        screens: [CGRect],
        minimumVisible: CGFloat = 40
    ) -> Bool {
        let frame = CGRect(origin: origin, size: size)
        return screens.contains { screen in
            let overlap = screen.intersection(frame)
            return !overlap.isNull
                && overlap.width >= minimumVisible
                && overlap.height >= minimumVisible
        }
    }
}
