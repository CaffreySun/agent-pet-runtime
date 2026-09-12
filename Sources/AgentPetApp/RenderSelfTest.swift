import AgentPetCore
import AppKit
import Foundation

/// Renders the pet offscreen and measures what actually lands in the buffer.
///
/// `screencapture` cannot see this app's windows without Screen Recording
/// permission, so a pixel count taken from the view's own backing store is the
/// only honest evidence that anything is being drawn. Run with
/// `AgentPet --selftest`.
@MainActor
enum RenderSelfTest {

    struct Result {
        let state: AgentState
        let trackName: String
        let opaquePixels: Int
        let totalPixels: Int
    }

    /// Draws `view` into an offscreen buffer and counts pixels with any alpha.
    static func measure(_ view: PetView) -> (opaque: Int, total: Int) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return (0, 0)
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let data = rep.bitmapData else { return (0, 0) }
        let samplesPerPixel = rep.samplesPerPixel
        guard samplesPerPixel >= 4 else { return (0, 0) }

        var opaque = 0
        let count = rep.pixelsWide * rep.pixelsHigh
        for index in 0..<count {
            // Alpha is the last sample in the RGBA layout AppKit hands back.
            if data[index * samplesPerPixel + 3] > 8 { opaque += 1 }
        }
        return (opaque, count)
    }

    static func run(controller: PetController, view: PetView) -> Int32 {
        print("Render self-test")
        print("")

        var failures = 0
        let states: [AgentState] = [.idle, .running, .waitingInput, .waitingApproval,
                                    .completed, .failed, .paused, .unknown]

        // Two states sharing a track must look identical; two states on
        // different tracks must not. Comparing raw state-to-state would flag
        // `waitingInput` and `waitingApproval` as a bug when they are in fact
        // deliberately the same animation.
        var rendersByTrack: [String: (signature: String, states: [AgentState])] = [:]

        for state in states {
            controller.previewState(state)
            guard let image = view.currentImage else {
                print("  ✗ \(state.rawValue): no image")
                failures += 1
                continue
            }

            let (opaque, total) = measure(view)
            let ratio = total > 0 ? Double(opaque) / Double(total) : 0
            let ok = opaque > 0
            if !ok { failures += 1 }

            let track = state.animationTrackName
            print(String(
                format: "  %@ %-16s -> %-9s %4dx%-4d  %6d / %6d visible px  (%.1f%%)",
                ok ? "✓" : "✗",
                (state.rawValue as NSString).utf8String!,
                (track as NSString).utf8String!,
                image.width, image.height,
                opaque, total, ratio * 100
            ))

            let signature = "\(image.width)x\(image.height):\(opaque)"
            if var existing = rendersByTrack[track] {
                if existing.signature != signature {
                    print("      ✗ same track '\(track)' rendered differently for "
                          + "\(existing.states.map(\.rawValue)) and \(state.rawValue)")
                    failures += 1
                }
                existing.states.append(state)
                rendersByTrack[track] = existing
            } else {
                rendersByTrack[track] = (signature, [state])
            }
        }

        // Distinct tracks must produce distinct pictures.
        var seen: [String: String] = [:]
        for (track, entry) in rendersByTrack.sorted(by: { $0.key < $1.key }) {
            if let other = seen[entry.signature] {
                print("  ✗ tracks '\(other)' and '\(track)' render identically")
                failures += 1
            }
            seen[entry.signature] = track
        }

        print("")
        print("  \(rendersByTrack.count) distinct tracks rendered from \(states.count) states")

        failures += checkDraggable(view: view)
        failures += checkBehaviourLayers(controller: controller, view: view)

        print("")
        print(failures == 0 ? "PASS" : "FAIL (\(failures) problem(s))")
        return failures == 0 ? 0 : 1
    }

    /// Checks the layers above the agent state — locomotion and gaze — which
    /// the state sweep above never exercises.
    private static func checkBehaviourLayers(controller: PetController, view: PetView) -> Int {
        print("")
        print("Behaviour layers")
        var failures = 0

        // Dragging must take over from whatever the agent is doing.
        controller.previewState(.waitingInput)
        let waitingBefore = view.currentImage
        controller.beginDrag()
        controller.updateDrag(dx: 12, dy: 0)
        let draggedRight = view.currentImage
        if draggedRight != nil, draggedRight !== waitingBefore {
            print("  ✓ dragging replaces the agent state with locomotion")
        } else {
            print("  ✗ dragging did not change the animation")
            failures += 1
        }

        controller.updateDrag(dx: -12, dy: 0)
        if view.currentImage !== draggedRight {
            print("  ✓ reversing the drag switches direction")
        } else {
            print("  ✗ the pet did not turn around when dragged the other way")
            failures += 1
        }

        controller.endDrag()
        controller.clearPreview()
        if view.currentImage !== draggedRight {
            print("  ✓ releasing returns the pet to its own animation")
        } else {
            print("  ✗ the pet stayed in locomotion after the drag ended")
            failures += 1
        }

        // Gaze only exists in a V2 atlas. A V1 pet has nowhere to put a
        // direction, so "no effect" is the correct result rather than a fault.
        guard let profile = controller.loadedProfile else {
            controller.clearPreview()
            return failures
        }
        guard profile.hasLookDirections else {
            print("  – gaze skipped: \(profile.displayName) has no look rows "
                  + "(a V2 pet is needed)")
            controller.clearPreview()
            return failures
        }

        controller.previewState(.idle)
        let idleFrame = view.currentImage
        controller.aimGaze(at: 90)   // straight right
        if view.currentImage != nil, view.currentImage !== idleFrame {
            print("  ✓ an idle pet turns to look toward the pointer")
        } else {
            print("  ✗ gaze had no effect on a \(profile.displayName) pet")
            failures += 1
        }

        controller.aimGaze(at: nil)
        if view.currentImage !== idleFrame {
            print("  ✓ with no direction the pet falls back to idle")
        } else {
            print("  ✗ the deadzone did not fall back to idle")
            failures += 1
        }

        // Gaze must not outrank an agent that is actually doing something.
        controller.aimGaze(at: 90)
        controller.previewState(.running)
        let working = view.currentImage
        controller.previewState(.idle)
        if view.currentImage !== working {
            print("  ✓ a working agent outranks where the pointer is")
        } else {
            print("  ✗ gaze overrode an active agent state")
            failures += 1
        }

        controller.aimGaze(at: nil)
        controller.clearPreview()
        return failures
    }

    /// Verifies the view will actually receive the click that starts a drag.
    ///
    /// Worth checking mechanically: the pet renders perfectly whether or not
    /// this works, and the failure mode is silent — a pet that animates but
    /// cannot be moved reads as a broken app with no visible cause.
    private static func checkDraggable(view: PetView) -> Int {
        print("")
        print("Drag readiness")
        var failures = 0

        // An accessory app is essentially never active, so without this the
        // first click would be spent activating and never reach the view.
        if view.acceptsFirstMouse(for: nil) {
            print("  ✓ acceptsFirstMouse — a click from another app reaches the pet")
        } else {
            print("  ✗ acceptsFirstMouse is false — the first click would be swallowed")
            failures += 1
        }

        // The centre of the view must be grabbable.
        let centre = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        if view.hitTest(centre) === view {
            print("  ✓ hitTest returns the pet at its centre")
        } else {
            print("  ✗ hitTest does not return the pet at its centre — it cannot be grabbed")
            failures += 1
        }

        // …and just outside it must pass clicks through, or the pet would
        // steal clicks meant for whatever is behind it.
        let outside = NSPoint(x: view.bounds.maxX + 20, y: view.bounds.midY)
        if view.hitTest(outside) == nil {
            print("  ✓ clicks outside the pet pass through to what is behind it")
        } else {
            print("  ✗ the pet captures clicks outside its own bounds")
            failures += 1
        }

        // Grab geometry must survive a round trip.
        let origin = CGPoint(x: 800, y: 300)
        let grab = WindowDrag.grabOffset(mouse: CGPoint(x: 850, y: 380), windowOrigin: origin)
        let returned = WindowDrag.origin(mouse: CGPoint(x: 850, y: 380), grabOffset: grab)
        if returned == origin {
            print("  ✓ drag geometry returns the window to its start")
        } else {
            print("  ✗ drag geometry drifts: \(origin) -> \(returned)")
            failures += 1
        }

        return failures
    }
}
