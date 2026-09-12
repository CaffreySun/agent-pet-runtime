import CoreGraphics
import Foundation
import Testing
@testable import AgentPetCore

@Suite("Window drag geometry")
struct WindowDragTests {

    @Test("grabbing records the cursor's offset inside the window")
    func grabOffset() {
        let offset = WindowDrag.grabOffset(
            mouse: CGPoint(x: 1100, y: 260),
            windowOrigin: CGPoint(x: 1000, y: 200)
        )
        #expect(offset == CGPoint(x: 100, y: 60))
    }

    @Test("moving the cursor moves the window by the same amount, keeping the grab point")
    func movesOneToOne() {
        let origin = CGPoint(x: 1000, y: 200)
        let grab = WindowDrag.grabOffset(mouse: CGPoint(x: 1100, y: 260), windowOrigin: origin)

        // Cursor moved +37, -12.
        let moved = WindowDrag.origin(mouse: CGPoint(x: 1137, y: 248), grabOffset: grab)
        #expect(moved == CGPoint(x: 1037, y: 188))
    }

    @Test("the point under the cursor at grab time stays under the cursor")
    func grabPointIsStable() {
        let origin = CGPoint(x: 500, y: 500)
        let mouseDown = CGPoint(x: 540, y: 560)
        let grab = WindowDrag.grabOffset(mouse: mouseDown, windowOrigin: origin)

        // However far the cursor travels, the same spot in the window stays
        // under it. This is the property a naive window-relative
        // implementation loses, and the window then drifts from the pointer.
        for mouse in [CGPoint(x: 600, y: 600), CGPoint(x: 100, y: 900), CGPoint(x: 540, y: 560)] {
            let newOrigin = WindowDrag.origin(mouse: mouse, grabOffset: grab)
            let pointUnderCursor = CGPoint(x: mouse.x - newOrigin.x, y: mouse.y - newOrigin.y)
            #expect(pointUnderCursor == grab, "cursor no longer holds the grab point at \(mouse)")
        }
    }

    @Test("a drag that returns to its start returns the window to where it began")
    func roundTrip() {
        let origin = CGPoint(x: 800, y: 300)
        let start = CGPoint(x: 850, y: 380)
        let grab = WindowDrag.grabOffset(mouse: start, windowOrigin: origin)

        var current = origin
        for mouse in [CGPoint(x: 900, y: 400), CGPoint(x: 1200, y: 100), start] {
            current = WindowDrag.origin(mouse: mouse, grabOffset: grab)
        }
        #expect(current == origin, "the window did not return to its starting position")
    }
}

@Suite("Window position clamping")
struct WindowClampingTests {

    private let primary = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let size = CGSize(width: 144, height: 156)

    @Test("a position inside a screen is left alone")
    func insideIsUnchanged() {
        let origin = CGPoint(x: 1000, y: 500)
        let clamped = WindowDrag.clamped(origin: origin, size: size, into: [primary])
        #expect(clamped == origin)
    }

    @Test("a pet dragged far off the right edge stays grabbable")
    func offRightEdgeClamped() {
        let clamped = WindowDrag.clamped(
            origin: CGPoint(x: 99_999, y: 500), size: size, into: [primary]
        )
        #expect(clamped.x < primary.maxX)
        #expect(WindowDrag.isReachable(origin: clamped, size: size, screens: [primary]))
    }

    @Test("a pet dragged far off the left edge stays grabbable")
    func offLeftEdgeClamped() {
        let clamped = WindowDrag.clamped(
            origin: CGPoint(x: -99_999, y: 500), size: size, into: [primary]
        )
        #expect(WindowDrag.isReachable(origin: clamped, size: size, screens: [primary]))
    }

    @Test("a pet dragged off the bottom stays grabbable")
    func offBottomClamped() {
        let clamped = WindowDrag.clamped(
            origin: CGPoint(x: 500, y: -99_999), size: size, into: [primary]
        )
        #expect(WindowDrag.isReachable(origin: clamped, size: size, screens: [primary]))
    }

    @Test("with no displays, the origin is returned unchanged rather than crashing")
    func noScreens() {
        let origin = CGPoint(x: 10, y: 10)
        #expect(WindowDrag.clamped(origin: origin, size: size, into: []) == origin)
    }

    @Test("the union of several displays is treated as usable space")
    func multipleScreens() {
        let below = CGRect(x: 0, y: -1440, width: 2560, height: 1440)
        let right = CGRect(x: 2560, y: -390, width: 1600, height: 1200)

        #expect(WindowDrag.isReachable(
            origin: CGPoint(x: 500, y: -1000), size: size, screens: [primary, below]
        ), "a pet on a display below the primary is reachable")
        #expect(WindowDrag.isReachable(
            origin: CGPoint(x: 2600, y: 100), size: size, screens: [primary, right]
        ), "a pet on a display to the right is reachable")
    }

    @Test("a position on a display that is no longer attached is unreachable")
    func detachedDisplay() {
        // Exactly the saved position from a monitor that has since been
        // unplugged — a pet there would be invisible and unclickable.
        #expect(!WindowDrag.isReachable(
            origin: CGPoint(x: 2600, y: 100), size: size, screens: [primary]
        ))
        #expect(!WindowDrag.isReachable(
            origin: CGPoint(x: 500, y: -1000), size: size, screens: [primary]
        ))
    }

    @Test("a fully off-screen frame is unreachable even if it overlaps nothing")
    func fullyOffscreen() {
        #expect(!WindowDrag.isReachable(
            origin: CGPoint(x: 5000, y: 5000), size: size, screens: [primary]
        ))
    }
}
