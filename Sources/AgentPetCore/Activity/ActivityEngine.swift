import Foundation

/// Tunables for the Activity Engine. The original spec named these mechanisms
/// but supplied no values; these are v0.1's, chosen so the pet feels calm
/// rather than twitchy, and exposed so they can be retuned without touching
/// the algorithm.
public struct ActivityTuning: Sendable, Equatable {
    /// How long an activity must sit in a stalled class before it is promoted.
    public var agingThreshold: TimeInterval
    /// Maximum number of classes aging can promote an activity.
    public var maxPromotions: Int
    /// A newly focused activity cannot be displaced for this long.
    public var focusHold: TimeInterval
    /// Relaxed hold that lets a blocking state interrupt a settled or idle one.
    public var urgentOverride: TimeInterval
    /// A completed activity is shown for at least this long.
    public var completionDwell: TimeInterval
    /// Repeated identical events within this window collapse into one.
    public var dedupeWindow: TimeInterval
    /// How long a session nothing has been heard from is kept at all.
    ///
    /// `SessionEnd` is the only clean ending, and a killed terminal, a crashed
    /// agent, or a status-line tap with no hooks behind it never sends one.
    /// Without a ceiling the engine keeps every session the machine has ever
    /// opened, and every frame pays for it.
    ///
    /// Far longer than the panel's row lifetime on purpose: this is when a
    /// session stops existing, not when it stops being worth drawing.
    public var silentSessionLifetime: TimeInterval

    public init(
        agingThreshold: TimeInterval = 90,
        maxPromotions: Int = 2,
        focusHold: TimeInterval = 3.0,
        urgentOverride: TimeInterval = 1.0,
        completionDwell: TimeInterval = 4.0,
        dedupeWindow: TimeInterval = 0.5,
        silentSessionLifetime: TimeInterval = 24 * 60 * 60
    ) {
        self.agingThreshold = agingThreshold
        self.maxPromotions = maxPromotions
        self.focusHold = focusHold
        self.urgentOverride = urgentOverride
        self.completionDwell = completionDwell
        self.dedupeWindow = dedupeWindow
        self.silentSessionLifetime = silentSessionLifetime
    }

    public static let `default` = ActivityTuning()
}

/// Decides which of several concurrently running agent sessions the pet should
/// be reacting to.
///
/// Pure, synchronous, and clock-injected: every decision is a function of the
/// events ingested and the current time, so the whole thing is deterministic
/// under test.
public final class ActivityEngine {
    public let tuning: ActivityTuning
    private let clock: ActivityClock

    private var activities: [SessionKey: AgentActivity] = [:]
    /// Order in which sessions first registered, used as a final deterministic
    /// tie-break so results never depend on dictionary iteration order.
    private var arrivalOrder: [SessionKey: Int] = [:]
    private var nextArrival = 0

    private var lastSeen: [SessionKey: (kind: AgentEventKind, at: Date, id: String?)] = [:]

    /// Sessions a process scan guessed at, by the process that was running.
    ///
    /// The guess is only what a process table can prove — a session of that
    /// agent exists — so the first event from the same process replaces it,
    /// whatever session id the agent turns out to use.
    private var placeholders: [Int32: SessionKey] = [:]

    private var focusedKey: SessionKey?
    private var focusAcquiredAt: Date?

    public private(set) var droppedEventCount = 0

    public init(tuning: ActivityTuning = .default, clock: ActivityClock = SystemActivityClock()) {
        self.tuning = tuning
        self.clock = clock
    }

    // MARK: - Ingest

    @discardableResult
    public func ingest(_ event: AgentEvent) -> AgentActivity? {
        let key = SessionKey(agentID: event.agentID, sessionID: event.sessionID)

        // A real event speaks for its process: whatever was inferred about that
        // process is now known better, and its placeholder goes.
        if !event.isPlaceholder, let processID = event.processID,
           let placeholder = placeholders.removeValue(forKey: processID), placeholder != key {
            forget(placeholder)
        }

        // A status-line reading describes a session rather than moving it, so
        // it takes its own path before deduplication and ordering: it never
        // touches the state, the aging clock, or the timeouts. Letting it
        // refresh `updatedAt` would mean a `running` session whose turn the
        // user interrupted stayed "working" forever, because the status line
        // keeps rendering at the prompt.
        //
        // Keyed on the kind, not on the presence of a context: an event can
        // carry both, and a state change that arrived with a reading attached
        // is still a state change.
        if event.kind == .contextUpdate, let context = event.context {
            return applyContext(context, event: event, key: key)
        }

        if isDuplicate(event, key: key) {
            droppedEventCount += 1
            return activities[key]
        }
        lastSeen[key] = (event.kind, event.at, event.eventID)

        if event.kind == .sessionClosed {
            forget(key)
            return nil
        }

        guard let newState = event.kind.resultingState else {
            droppedEventCount += 1
            return nil
        }

        if var existing = activities[key] {
            // Out-of-order delivery must not rewind a session. Agents emit
            // hooks from several processes, so ordering is not guaranteed.
            if event.at < existing.updatedAt {
                droppedEventCount += 1
                return existing
            }

            let stateChanged = existing.state != newState
            // A clickable target, once known, should not be lost to a later
            // event that happens not to carry one.
            if let focus = event.focusTarget, focus.kind != .none {
                existing.focusTarget = focus
            }
            if let summary = event.summary { existing.title = summary }
            if let detail = event.detail { existing.detail = detail }
            if let tool = event.toolName { existing.toolName = tool }
            if let context = event.context {
                existing.context = existing.context?.merging(context) ?? context
            }

            existing.state = newState
            existing.confidence = event.confidence
            existing.updatedAt = event.at
            if stateChanged { existing.enteredStateAt = event.at }

            activities[key] = existing
            return existing
        }

        let activity = AgentActivity(
            agentID: event.agentID,
            sessionID: event.sessionID,
            state: newState,
            confidence: event.confidence,
            title: event.summary,
            detail: event.detail,
            toolName: event.toolName,
            focusTarget: event.focusTarget,
            context: event.context,
            startedAt: event.at,
            updatedAt: event.at,
            enteredStateAt: event.at
        )
        arrivalOrder[key] = nextArrival
        nextArrival += 1
        activities[key] = activity
        if event.isPlaceholder, let processID = event.processID {
            placeholders[processID] = key
        }
        return activity
    }

    /// Forgets one session, the way `sessionClosed` does.
    private func forget(_ key: SessionKey) {
        activities.removeValue(forKey: key)
        arrivalOrder.removeValue(forKey: key)
        lastSeen.removeValue(forKey: key)
        placeholders = placeholders.filter { $0.value != key }
        if focusedKey == key { clearFocus() }
    }

    /// The processes still being guessed at, so a caller can ask the process
    /// table whether they are still there.
    public var placeholderProcessIDs: [Int32] { Array(placeholders.keys) }

    /// Drops the placeholder a process left behind.
    public func forgetPlaceholder(processID: Int32) {
        if let key = placeholders.removeValue(forKey: processID) { forget(key) }
    }

    /// Attaches a status-line reading to the session it belongs to.
    ///
    /// A reading is also proof that the session exists, so one arriving for a
    /// session nothing else has reported creates it — `idle`, because a status
    /// line says what a session *is*, not what it is doing. That is what lets
    /// the panel show every open session after a restart rather than only the
    /// ones that happened to fire a hook.
    private func applyContext(
        _ context: SessionContext,
        event: AgentEvent,
        key: SessionKey
    ) -> AgentActivity? {
        if var existing = activities[key] {
            existing.context = existing.context?.merging(context) ?? context
            activities[key] = existing
            return existing
        }

        let activity = AgentActivity(
            agentID: event.agentID,
            sessionID: event.sessionID,
            state: .idle,
            confidence: event.confidence,
            context: context,
            startedAt: event.at,
            updatedAt: event.at,
            enteredStateAt: event.at
        )
        arrivalOrder[key] = nextArrival
        nextArrival += 1
        activities[key] = activity
        return activity
    }

    private func isDuplicate(_ event: AgentEvent, key: SessionKey) -> Bool {
        guard let last = lastSeen[key] else { return false }
        // An explicit id from the agent is authoritative when both sides have one.
        if let id = event.eventID, let previous = last.id { return id == previous }
        guard last.kind == event.kind else { return false }
        return event.at.timeIntervalSince(last.at) < tuning.dedupeWindow
    }

    // MARK: - Time

    /// Applies silence timeouts, and lets go of sessions that have been silent
    /// long enough that only a missing `SessionEnd` was keeping them.
    ///
    /// Called implicitly by `currentFocus()`, `rankedActivities()`, and
    /// `allActivities()`, so nothing can report a session the engine has
    /// already forgotten.
    public func expireStale() {
        let now = clock.now
        var transitions: [(SessionKey, AgentState)] = []

        for (key, activity) in activities {
            guard let timeout = activity.state.staleTimeout,
                  let successor = activity.state.staleSuccessor,
                  now.timeIntervalSince(activity.updatedAt) >= timeout
            else { continue }
            transitions.append((key, successor))
        }

        for (key, successor) in transitions {
            guard var activity = activities[key] else { continue }
            activity.state = successor
            // The degradation happens now, so that is when the new state's
            // aging clock starts.
            activity.enteredStateAt = now
            activities[key] = activity
        }

        evictSilent(now: now)
    }

    /// Forgets sessions that have not been heard from for
    /// `tuning.silentSessionLifetime`.
    ///
    /// A terminal that was killed, an agent that crashed, and a status-line
    /// tap with no hooks installed all leave a session that never closes, and
    /// an unclosed session is not a session that is still there: the panel
    /// stops drawing an idle row after ten minutes for exactly that reason.
    /// Left unbounded the three tables grow with every terminal the machine
    /// has ever opened, and — because `currentFocus()` walks the whole table
    /// every frame — the cost lands on the animation loop.
    ///
    /// Not a state change, and not a verdict: an agent that is still alive
    /// re-creates its session with its next hook, one event later.
    private func evictSilent(now: Date) {
        let cutoff = now.addingTimeInterval(-tuning.silentSessionLifetime)
        var forgotten: [SessionKey] = []
        for (key, activity) in activities where activity.lastHeardAt < cutoff {
            forgotten.append(key)
        }
        guard !forgotten.isEmpty else { return }

        for key in forgotten { forget(key) }
    }

    // MARK: - Selection

    public func allActivities() -> [AgentActivity] {
        expireStale()
        return activities.values.sorted {
            arrivalOrder[$0.key, default: 0] < arrivalOrder[$1.key, default: 0]
        }
    }

    public func activity(for key: SessionKey) -> AgentActivity? {
        activities[key]
    }

    /// Which activity the pet should be showing, or `nil` if nothing is worth
    /// showing.
    public func currentFocus() -> AgentActivity? {
        expireStale()
        let now = clock.now

        guard let candidate = rankedCandidates(now: now).first else {
            clearFocus()
            return nil
        }

        guard let currentKey = focusedKey, let current = activities[currentKey] else {
            setFocus(candidate, at: now)
            return candidate
        }

        if currentKey == candidate.key { return current }

        let heldFor = now.timeIntervalSince(focusAcquiredAt ?? now)

        // A completed activity gets a minimum showing so the celebration is
        // not clipped by a session that outranks it a moment later. Measured
        // from when the session finished, not from when it took focus: the
        // celebration starts when the work ends.
        if current.state == .completed,
           now.timeIntervalSince(current.enteredStateAt) < tuning.completionDwell {
            return current
        }

        if heldFor < tuning.focusHold {
            let urgent = candidate.state.priorityClass == .attention
                && current.state.priorityClass >= .settled
                && heldFor >= tuning.urgentOverride
            if !urgent { return current }
        }

        setFocus(candidate, at: now)
        return candidate
    }

    /// Every session the pet could be showing, best first.
    ///
    /// The same order focus is decided by, exposed so the message panel lists
    /// sessions in the order the pet itself cares about — the blocked session
    /// above the working one — instead of the order they happened to arrive.
    public func rankedActivities() -> [AgentActivity] {
        expireStale()
        return rankedCandidates(now: clock.now)
    }

    /// Ranked best-first, fully deterministic.
    private func rankedCandidates(now: Date) -> [AgentActivity] {
        activities.values.sorted { lhs, rhs in
            let lc = effectiveClass(lhs, now: now)
            let rc = effectiveClass(rhs, now: now)
            if lc != rc { return lc < rc }

            // Within the attention class, "your turn" outranks a permission
            // prompt: the former is a finished turn awaiting the user, the
            // latter is usually transient and often auto-approved.
            let ls = attentionRank(lhs.state)
            let rs = attentionRank(rhs.state)
            if ls != rs { return ls < rs }

            if lhs.enteredStateAt != rhs.enteredStateAt {
                return lhs.enteredStateAt < rhs.enteredStateAt
            }
            if lhs.agentID != rhs.agentID { return lhs.agentID < rhs.agentID }
            return lhs.sessionID < rhs.sessionID
        }
    }

    private func attentionRank(_ state: AgentState) -> Int {
        switch state {
        case .waitingInput:    return 0
        case .waitingApproval: return 1
        default:               return 2
        }
    }

    /// Priority after aging.
    ///
    /// Aging exists so a session that has been stuck for minutes is not drowned
    /// out by one that just started. It applies only to stalled states —
    /// a long-running task is making progress, not waiting, and must not
    /// accumulate seniority.
    public func effectiveClass(_ activity: AgentActivity, now: Date) -> PriorityClass {
        let base = activity.state.priorityClass
        guard base == .failure || base == .settled else { return base }

        let waited = now.timeIntervalSince(activity.enteredStateAt)
        guard waited >= tuning.agingThreshold else { return base }

        let promotions = min(Int(waited / tuning.agingThreshold), tuning.maxPromotions)
        let raw = max(base.rawValue - promotions, PriorityClass.attention.rawValue)
        return PriorityClass(rawValue: raw) ?? base
    }

    // MARK: - Focus bookkeeping

    private func setFocus(_ activity: AgentActivity, at now: Date) {
        focusedKey = activity.key
        focusAcquiredAt = now
    }

    private func clearFocus() {
        focusedKey = nil
        focusAcquiredAt = nil
    }

    /// Held for tests and for the "Reconfigure" path.
    public func reset() {
        activities.removeAll()
        arrivalOrder.removeAll()
        lastSeen.removeAll()
        placeholders.removeAll()
        nextArrival = 0
        droppedEventCount = 0
        clearFocus()
    }
}
