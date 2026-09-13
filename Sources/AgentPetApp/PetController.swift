import AgentPetCore
import AppKit

/// Drives the pet's animation from the activity engine and the user's hands.
///
/// The frame on screen is a pure function of a `PetSituation`, so previewing a
/// state, reacting to a real agent, and being dragged all go through the same
/// resolver. There is no separate "demo mode" to drift out of sync with the
/// real thing.
@MainActor
final class PetController {

    /// Frame rate of the sampling loop. Frames are chosen by elapsed time, not
    /// by tick count, so this only bounds animation smoothness.
    private static let tickInterval: TimeInterval = 1.0 / 60.0

    /// How close the pointer must come before it stops meaning a direction.
    ///
    /// The contract calls this the no-vector deadzone: with no meaningful
    /// vector there is no gaze angle to pick, and the pet falls back to idle.
    private static let gazeDeadzone: CGFloat = 28

    private let engine: ActivityEngine
    private let resolver = AnimationResolver()

    private var frames: SpriteFrames?
    private var timer: Timer?

    private var lastRenderedState: AgentState?
    private var stateEnteredAt = Date()

    /// Non-nil while the user is dragging.
    private var drag: (direction: HorizontalDirection, startedAt: Date)?

    /// Non-nil while a one-shot gesture is playing over the steady state.
    private var gesture: (track: AnimationTrack, startedAt: Date)?

    /// Set by the self-test to pin a single state.
    private var forcedState: AgentState?

    /// Set by the self-test to pin how far into that state's animation a
    /// render sits. Without it every render samples frame zero, and a package
    /// whose rows share their opening pose — a common way to author these
    /// sheets — looks like it has duplicate animations.
    private var forcedElapsed: TimeInterval?

    /// The message shown beside the pet, or nil when there is nothing to say.
    ///
    /// Ported from Codex's ambient pet: each session state speaks in one of
    /// four kinds, the message is stamped when it is set, and it expires on
    /// that kind's lifetime.
    private var message: PetNotification?

    /// What the view should draw beside the sprite, if anything.
    var currentNotification: PetNotification? {
        guard let message, !message.isExpired(at: Date()) else { return nil }
        return message
    }

    /// Every rendered frame, with the message that belongs beside it.
    var onFrame: ((CGImage?, PetNotification?) -> Void)?

    /// Where the pet is on screen, so gaze can be aimed at the pointer.
    var petCenterProvider: (() -> CGPoint?)?

    init(tuning: ActivityTuning = .default) {
        self.engine = ActivityEngine(tuning: tuning)
    }

    // No `deinit` teardown: `Timer` is not `Sendable`, so a nonisolated deinit
    // cannot reach it under strict concurrency. The owner calls `stop()`.

    // MARK: - Content

    var loadedPetName: String?

    /// The profile of the pet currently loaded, for callers that need to know
    /// what it can do — a V1 atlas has no gaze poses.
    var loadedProfile: CompatibilityProfile? { frames?.profile }

    func load(_ package: LoadedPetPackage) throws {
        guard let atlas = package.atlas else {
            throw SpriteFramesError.cannotCreateImage
        }
        frames = try SpriteFrames(bitmap: atlas, profile: package.definition.profile)
        lastRenderedState = nil
        render()
    }

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

    /// The session the pet is currently showing.
    var focusedActivity: AgentActivity? {
        forcedState != nil ? nil : engine.currentFocus()
    }

    // MARK: - Gestures

    /// Plays a one-shot track over whatever else is happening.
    func playGesture(named name: String) {
        guard let profile = frames?.profile, let track = profile.track(named: name) else { return }
        gesture = (track, Date())
        render()
    }

    /// The pet waves when it is clicked — the contract's "greeting or
    /// attention gesture".
    func greet() {
        playGesture(named: "waving")
    }

    // MARK: - Dragging

    /// The pet is picked up. Locomotion takes over from whatever it was doing:
    /// the contract gives it dedicated rows so it can walk while carried.
    func beginDrag() {
        drag = (lastDragDirection, Date())
        render()
    }

    /// Feeds the drag's movement so the pet turns to face the way it is going.
    ///
    /// Vertical movement has no row of its own, and it must not flip the pet
    /// back and forth as the cursor wobbles, so a mostly-vertical drag keeps
    /// the direction it already had.
    func updateDrag(dx: CGFloat, dy: CGFloat) {
        guard let current = drag else { return }
        let direction = HorizontalDirection.from(
            dx: dx, dy: dy, previous: current.direction
        ) ?? current.direction
        lastDragDirection = direction
        drag = (direction, current.startedAt)
        render()
    }

    /// The drag ended. The pet returns to its own animation, and immediately,
    /// rather than finishing a locomotion cycle it is no longer doing.
    func endDrag() {
        drag = nil
        render()
    }

    /// Remembered between drags so a pet picked up and set down repeatedly does
    /// not reset to facing right each time.
    private var lastDragDirection: HorizontalDirection = .right

    // MARK: - Self-test support

    /// Pins the animation to a single state, bypassing the activity engine.
    func previewState(_ state: AgentState) {
        forcedState = state
        forcedElapsed = nil
        gesture = nil
        drag = nil
        lastRenderedState = nil
        render()
    }

    /// Pins the state *and* how far into its animation the render sits.
    func previewState(_ state: AgentState, elapsed: TimeInterval) {
        previewState(state)
        forcedElapsed = elapsed
        render()
    }

    func clearPreview() {
        forcedState = nil
        forcedElapsed = nil
        render()
    }

    /// Pins the gaze angle instead of reading the pointer. Used by the
    /// self-test, which has no mouse.
    func aimGaze(at angle: Double?) {
        forcedGaze = angle
        render()
    }

    private var forcedGaze: Double??

    // MARK: - Loop

    func start() {
        stop()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.render() }
        }
        // `.common` keeps the pet animating while a menu is open or the user is
        // dragging, which the default mode would freeze.
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
        let now = Date()

        let state = currentState(now: now)
        updateMessage(for: state, now: now)

        let situation = PetSituation(
            agentState: state,
            agentStateElapsed: forcedElapsed ?? now.timeIntervalSince(stateEnteredAt),
            drag: drag.map { PetSituation.Drag(direction: $0.direction,
                                               elapsed: now.timeIntervalSince($0.startedAt)) },
            gesture: activeGesture(now: now),
            lookAngle: gazeAngle()
        )

        let frame = resolver.resolve(situation, profile: frames.profile)
        onFrame?(frame.flatMap { frames.image(for: $0) }, currentNotification)
    }

    /// Keeps the message in step with what the pet is showing.
    ///
    /// Codex sets a notification when a turn starts, when an approval is
    /// asked for, when a turn completes, and when it fails; the message stays
    /// until it is replaced or its lifetime runs out. Here the state already
    /// comes from the activity engine, so the message follows it, and the
    /// lifetimes cap how long a stale one could linger.
    private func updateMessage(for state: AgentState, now: Date) {
        guard let kind = PetNotificationKind.forState(state) else {
            message = nil
            return
        }
        let candidate = PetNotification(
            kind: kind, body: Self.detail(for: kind, activity: focusedActivity), setAt: now
        )
        // Unchanged means unchanged: re-stamping every frame would keep a
        // message alive forever instead of letting its lifetime run out.
        if let current = message, current.kind == candidate.kind, current.body == candidate.body {
            return
        }
        message = candidate
    }

    /// What the second line can say, per kind.
    ///
    /// Codex fills exactly one body — the assistant's message preview for
    /// `review` — from a model stream this runtime is not: the shim forwards
    /// event metadata, never model output, so there is nothing to preview and
    /// the label stands alone. `waiting` and `failed` do have specifics worth
    /// showing, and they are the ones Codex's own desktop notifications show
    /// too: the tool an approval is for, and what went wrong.
    ///
    /// `running` deliberately shows nothing extra: the only text the event
    /// carries there is the user's prompt, and putting what someone typed on
    /// a floating panel over their screen is not a trade this app makes.
    private static func detail(for kind: PetNotificationKind, activity: AgentActivity?) -> String? {
        switch kind {
        case .waiting, .failed: return activity?.title
        case .running, .review: return nil
        }
    }

    private func currentState(now: Date) -> AgentState {
        let state = forcedState ?? engine.currentFocus()?.state ?? .idle
        if state != lastRenderedState {
            lastRenderedState = state
            stateEnteredAt = now
        }
        return state
    }

    private func activeGesture(now: Date) -> PetSituation.Gesture? {
        guard let gesture else { return nil }
        let elapsed = now.timeIntervalSince(gesture.startedAt)
        guard elapsed < gesture.track.duration else {
            self.gesture = nil
            return nil
        }
        return PetSituation.Gesture(trackName: gesture.track.name, elapsed: elapsed)
    }

    /// Where the pointer is, relative to the pet, as degrees clockwise from up.
    ///
    /// Only computed for profiles that have gaze rows: a V1 pet has nowhere to
    /// put the answer, so polling the pointer for it would be work with no
    /// purpose.
    private func gazeAngle() -> Double? {
        // `forcedGaze` is a double optional so the self-test can distinguish
        // "no override" from "override to no direction".
        if let forcedGaze { return forcedGaze }

        guard frames?.profile.hasLookDirections == true,
              let center = petCenterProvider?()
        else { return nil }

        let pointer = NSEvent.mouseLocation
        let distance = hypot(pointer.x - center.x, pointer.y - center.y)
        guard distance > Self.gazeDeadzone else { return nil }

        return LookDirection.angle(from: center, to: pointer)
    }
}
