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

    /// When the pointer arrived on the pet, or nil if it is not there. Codex
    /// plays its `jumping` row for this and holds the landing pose, so the
    /// only fact the layer needs is when the hover began.
    private var hoverStartedAt: Date?

    /// Set by the self-test to pin a single state.
    private var forcedState: AgentState?

    /// Set by the self-test to pin how far into that state's animation a
    /// render sits. Without it every render samples frame zero, and a package
    /// whose rows share their opening pose — a common way to author these
    /// sheets — looks like it has duplicate animations.
    private var forcedElapsed: TimeInterval?

    /// The rows shown beside the pet: one per session, grouped by agent.
    ///
    /// Rebuilt on every event and at most once a second otherwise — the state
    /// machine ages sessions on a clock, so a panel built only on events would
    /// go stale while nothing was arriving, and one built sixty times a second
    /// would be work with no result.
    private(set) var panel: MessagePanel = .empty
    private var lastPanelBuild = Date.distantPast

    /// How the panel is configured. Asked rather than stored, so a change in
    /// the manager shows up without the controller knowing a window exists.
    var panelConfig: () -> MessagePanelConfig = { MessagePanelConfig() }

    /// Display names for agents, by id.
    var agentNames: () -> [String: String] = { [:] }

    /// Every rendered frame, with the panel that belongs beside it.
    var onFrame: ((CGImage?, MessagePanel) -> Void)?

    /// Where the pet is on screen, so gaze can be aimed at the pointer.
    var petCenterProvider: (() -> CGPoint?)?

    /// Whether to hold still. The answer is the user's setting *and* the
    /// system's request, and it changes while the app runs, so it is asked
    /// rather than stored.
    var shouldReduceMotion: () -> Bool = { false }

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
        rebuildPanel(now: Date())
        render()
    }

    func resetActivities() {
        engine.reset()
        lastRenderedState = nil
        gesture = nil
        panel = .empty
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
        // Set down under the pointer: the pet jumps again, which is what Codex
        // does — its sprite restarts a row whenever the animation it is
        // showing changes back to it.
        if hoverStartedAt != nil { hoverStartedAt = Date() }
        render()
    }

    // MARK: - Hover

    /// The pointer arrived on the pet.
    func beginHover() {
        guard hoverStartedAt == nil else { return }
        hoverStartedAt = Date()
        render()
    }

    /// The pointer left. The pet goes back to whatever the agent is doing.
    func endHover() {
        guard hoverStartedAt != nil else { return }
        hoverStartedAt = nil
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
        // A preview is of one animation, not of the user's sessions.
        panel = .empty
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
        rebuildPanel(now: Date())
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

        // The panel ages on its own — a session goes quiet, a row stops being
        // worth showing — so it is rebuilt on the clock as well as on events.
        if now.timeIntervalSince(lastPanelBuild) >= 1 {
            rebuildPanel(now: now)
        }

        let state = currentState(now: now)

        let situation = PetSituation(
            agentState: state,
            agentStateElapsed: forcedElapsed ?? now.timeIntervalSince(stateEnteredAt),
            drag: drag.map { PetSituation.Drag(direction: $0.direction,
                                               elapsed: now.timeIntervalSince($0.startedAt)) },
            gesture: activeGesture(now: now),
            hover: hoverStartedAt.map { PetSituation.Hover(elapsed: now.timeIntervalSince($0)) },
            lookAngle: gazeAngle(),
            reducedMotion: shouldReduceMotion()
        )

        let frame = resolver.resolve(situation, profile: frames.profile)
        onFrame?(frame.flatMap { frames.image(for: $0) }, panel)
    }

    /// Rebuilds the rows from the engine's current view of the world.
    private func rebuildPanel(now: Date) {
        lastPanelBuild = now
        let focused = forcedState != nil ? nil : engine.currentFocus()
        panel = MessagePanel.build(
            ranked: engine.rankedActivities(),
            focusedID: focused?.id,
            agentNames: agentNames(),
            config: panelConfig(),
            now: now
        )
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
