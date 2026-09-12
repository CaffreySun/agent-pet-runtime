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

        print("")
        print(failures == 0 ? "PASS" : "FAIL (\(failures) problem(s))")
        return failures == 0 ? 0 : 1
    }
}
