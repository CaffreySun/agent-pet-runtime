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

    public init(
        agingThreshold: TimeInterval = 90,
        maxPromotions: Int = 2,
        focusHold: TimeInterval = 3.0,
        urgentOverride: TimeInterval = 1.0,
        completionDwell: TimeInterval = 4.0,
        dedupeWindow: TimeInterval = 0.5
    ) {
        self.agingThreshold = agingThreshold
        self.maxPromotions = maxPromotions
        self.focusHold = focusHold
        self.urgentOverride = urgentOverride
        self.completionDwell = completionDwell
        self.dedupeWindow = dedupeWindow
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
            activities.removeValue(forKey: key)
            arrivalOrder.removeValue(forKey: key)
            lastSeen.removeValue(forKey: key)
            if focusedKey == key { clearFocus() }
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
        return activity
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

    /// Applies silence timeouts. Called implicitly by `currentFocus()`.
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
    }

    // MARK: - Selection

    public func allActivities() -> [AgentActivity] {
        activities.values.sorted { arrivalOrder[$0.key, default: 0] < arrivalOrder[$1.key, default: 0] }
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
        rankedCandidates(now: clock.now)
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
        nextArrival = 0
        droppedEventCount = 0
        clearFocus()
    }
}
