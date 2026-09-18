import Foundation

/// Keeps the panel's width from twitching.
///
/// When the panel fits itself to its content, the content changes with every
/// event: a session goes from `Running` to `Needs input`, a tool name appears,
/// an assistant's message lands. Drawing each of those at its own exact width
/// would have the bubble flinch sideways every few seconds.
///
/// So the width grows the moment something needs the room — new information
/// must not be cut — and shrinks only once the content has stayed narrower
/// for `shrinkDelay`. A value type that carries its own state, so the caller
/// holds one stored property and the rule is testable without a window.
public struct PanelWidthGovernor: Sendable, Equatable {

    /// How long the content has to stay narrower before the panel follows it
    /// back down. Long enough to ride out a turn's events: a tool label
    /// disappearing between two hooks is not a reason to move the window.
    public static let defaultShrinkDelay: TimeInterval = 2

    public let shrinkDelay: TimeInterval

    /// The width in force, or nil before the first target arrives.
    public private(set) var width: CGFloat?
    /// When the content first asked for something narrower than `width`.
    private var wantedNarrowerSince: Date?

    public init(shrinkDelay: TimeInterval = PanelWidthGovernor.defaultShrinkDelay) {
        self.shrinkDelay = shrinkDelay
    }

    /// The width to draw at now, given what the content asks for.
    public mutating func width(wanted: CGFloat, at now: Date) -> CGFloat {
        guard let current = width else {
            width = wanted
            return wanted
        }
        if wanted >= current {
            // Anything that needs room takes it at once, and cancels a shrink
            // that was waiting out its delay.
            width = wanted
            wantedNarrowerSince = nil
            return wanted
        }
        if let since = wantedNarrowerSince, now.timeIntervalSince(since) >= shrinkDelay {
            width = wanted
            wantedNarrowerSince = nil
            return wanted
        }
        // Still inside the delay: the clock runs from the first request to
        // shrink, not from the latest one, so a stream of slightly different
        // widths does not postpone the shrink forever.
        if wantedNarrowerSince == nil { wantedNarrowerSince = now }
        return current
    }

    /// Forget the width in force, so the next target is adopted at once. For
    /// the pet being put away and brought back: a panel should not come up at
    /// a width from minutes ago.
    public mutating func reset() {
        width = nil
        wantedNarrowerSince = nil
    }
}
