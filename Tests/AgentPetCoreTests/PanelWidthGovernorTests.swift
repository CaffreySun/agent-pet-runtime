import AgentPetCore
import Foundation
import Testing

@Suite("Panel width governor")
struct PanelWidthGovernorTests {

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("the first target is adopted at once")
    func adoptsTheFirstTarget() {
        var governor = PanelWidthGovernor()
        #expect(governor.width(wanted: 286, at: start) == 286)
        #expect(governor.width == 286)
    }

    @Test("a width that needs more room is taken at once")
    func growsImmediately() {
        var governor = PanelWidthGovernor()
        _ = governor.width(wanted: 286, at: start)
        // Half a second later — well inside any delay — the content is wider.
        #expect(governor.width(wanted: 340, at: start.addingTimeInterval(0.5)) == 340)
    }

    @Test("a narrower width waits for the delay, then follows")
    func shrinksAfterTheDelay() {
        var governor = PanelWidthGovernor(shrinkDelay: 2)
        _ = governor.width(wanted: 340, at: start)

        // Just inside the delay — measured from the first request to shrink,
        // which is this 0.5s call: still wide.
        #expect(governor.width(wanted: 286, at: start.addingTimeInterval(0.5)) == 340)
        #expect(governor.width(wanted: 286, at: start.addingTimeInterval(1.9)) == 340)
        #expect(governor.width(wanted: 286, at: start.addingTimeInterval(2.4)) == 340)
        // Past it: narrow.
        #expect(governor.width(wanted: 286, at: start.addingTimeInterval(2.6)) == 286)
    }

    @Test("the clock runs from the first request to shrink, not the latest")
    func aStreamOfNarrowerWidthsStillSettles() {
        var governor = PanelWidthGovernor(shrinkDelay: 2)
        _ = governor.width(wanted: 400, at: start)
        for step in stride(from: 0.0, through: 1.9, by: 0.2) {
            // A slightly different narrow width every time — the message
            // column changing as a detail is typed out.
            _ = governor.width(wanted: 300 - step * 10, at: start.addingTimeInterval(step))
        }
        // 2.1s after the *first* narrow target, the panel follows the content.
        #expect(governor.width(wanted: 286, at: start.addingTimeInterval(2.1)) == 286)
    }

    @Test("needing room again cancels a shrink that was waiting")
    func growingCancelsAPendingShrink() {
        var governor = PanelWidthGovernor(shrinkDelay: 2)
        _ = governor.width(wanted: 340, at: start)
        _ = governor.width(wanted: 286, at: start.addingTimeInterval(1))   // waiting
        _ = governor.width(wanted: 340, at: start.addingTimeInterval(1.5)) // needs it back
        // The delay starts over: still wide a second later, and a second
        // after that — 2.5s is when the narrow content came back.
        #expect(governor.width(wanted: 286, at: start.addingTimeInterval(2.5)) == 340)
        #expect(governor.width(wanted: 286, at: start.addingTimeInterval(3.5)) == 340)
        // ...and follows once it has held for the delay.
        #expect(governor.width(wanted: 286, at: start.addingTimeInterval(4.6)) == 286)
    }

    @Test("reset makes the next target immediate")
    func resetForgetsTheWidth() {
        var governor = PanelWidthGovernor(shrinkDelay: 2)
        _ = governor.width(wanted: 340, at: start)
        governor.reset()
        #expect(governor.width == nil)
        #expect(governor.width(wanted: 200, at: start.addingTimeInterval(0.1)) == 200)
    }
}
