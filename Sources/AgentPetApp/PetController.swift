import AgentPetCore
import AppKit

/// Drives the pet's animation from the activity engine.
///
/// The frame on screen is a pure function of what the engine currently
/// focuses on, so previewing a state and reacting to a real agent both go
/// through the same path. There is no separate "demo mode" to drift out of
/// sync with the real thing.
@MainActor
final class PetController {

    /// Frame rate of the sampling loop. Tracks are sampled by elapsed time,
    /// not by tick count, so this only bounds animation smoothness.
    private static let tickInterval: TimeInterval = 1.0 / 60.0

    private let engine: ActivityEngine
    private let resolver = AnimationResolver()

    private var frames: SpriteFrames?
    private var timer: Timer?

    /// Set while a one-shot gesture is playing over the steady state.
    private var gesture: (track: AnimationTrack, startedAt: Date)?
    private var lastRenderedState: AgentState?
    private var stateEnteredAt = Date()

    var onFrame: ((CGImage?) -> Void)?

    init(tuning: ActivityTuning = .default) {
        self.engine = ActivityEngine(tuning: tuning)
    }

    // No `deinit` teardown: `Timer` is not `Sendable`, so a nonisolated deinit
    // cannot reach it under strict concurrency. The owner calls `stop()`.

    // MARK: - Content

    func load(_ package: LoadedPetPackage) throws {
        guard let atlas = package.atlas else {
            throw SpriteFramesError.cannotCreateImage
        }
        frames = try SpriteFrames(bitmap: atlas, profile: package.definition.profile)
        lastRenderedState = nil
        render()
    }

    var loadedPetName: String?

    // MARK: - Activity

    func ingest(_ event: AgentEvent) {
        engine.ingest(event)
        render()
    }

    func resetActivities() {
        engine.reset()
        lastRenderedState = nil
        gesture = nil
        render()
    }

    var currentActivities: [AgentActivity] { engine.allActivities() }

    /// Plays a one-shot track over the current state — used by the preview menu
    /// and by the integration test button.
    func playGesture(named name: String) {
        guard let profile = frames?.profile, let track = profile.track(named: name) else { return }
        gesture = (track, Date())
        render()
    }

    /// Pins the animation to a single state, bypassing the activity engine.
    /// Used by the render self-test to hold each state still long enough to
    /// measure it.
    ///
    /// Clears any pending gesture: a preview must show the state's own track,
    /// not whatever transient animation happened to still be playing.
    func previewState(_ state: AgentState) {
        forcedState = state
        gesture = nil
        // Force the state transition to register so the track restarts at
        // frame 0 rather than mid-animation.
        lastRenderedState = nil
        render()
    }

    func clearPreview() {
        forcedState = nil
        render()
    }

    private var forcedState: AgentState?

    // MARK: - Loop

    func start() {
        stop()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        // `.common` keeps the pet animating while a menu is open or the user is
        // dragging the window, which the default mode would freeze.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Rendering

    private func render() {
        guard let frames else { return }

        let state = forcedState ?? engine.currentFocus()?.state ?? .idle
        let now = Date()

        if state != lastRenderedState {
            // Entering `completed` is the cue for the celebration gesture.
            if state == .completed, lastRenderedState != nil,
               let waving = frames.profile.track(named: "waving") {
                gesture = (waving, now)
            }
            lastRenderedState = state
            stateEnteredAt = now
        }

        var activeGesture: (track: AnimationTrack, elapsed: TimeInterval)?
        if let gesture {
            let elapsed = now.timeIntervalSince(gesture.startedAt)
            if elapsed < gesture.track.duration {
                activeGesture = (gesture.track, elapsed)
            } else {
                self.gesture = nil
            }
        }

        let frame = resolver.resolve(
            state: state,
            profile: frames.profile,
            stateElapsed: now.timeIntervalSince(stateEnteredAt),
            gesture: activeGesture
        )

        onFrame?(frame.flatMap { frames.image(for: $0) })
    }
}
