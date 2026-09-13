import Foundation
import Testing
@testable import AgentPetCore

/// The ported notification model.
///
/// The expected strings and durations here are not invented: they are Codex's
/// own, taken from `codex-rs/tui/src/pets/ambient.rs`, which carries them with
/// a test asserting the vocabulary matches the Codex app's.
@Suite("Pet notifications")
struct PetNotificationTests {

    @Test("labels are Codex's own vocabulary")
    func labels() {
        #expect(PetNotificationKind.running.label == "Running")
        #expect(PetNotificationKind.waiting.label == "Needs input")
        #expect(PetNotificationKind.review.label == "Ready")
        #expect(PetNotificationKind.failed.label == "Blocked")
    }

    @Test("fallback bodies match Codex's, including Running's second line")
    func fallbackBodies() {
        #expect(PetNotificationKind.running.fallbackBody == "Thinking")
        #expect(PetNotificationKind.waiting.fallbackBody == "Needs input")
        #expect(PetNotificationKind.review.fallbackBody == "Ready")
        #expect(PetNotificationKind.failed.fallbackBody == "Blocked")

        // Three kinds collapse to one line; running keeps two.
        #expect(!PetNotification(kind: .waiting, setAt: Date()).showsDetail)
        #expect(!PetNotification(kind: .review, setAt: Date()).showsDetail)
        #expect(!PetNotification(kind: .failed, setAt: Date()).showsDetail)
        #expect(PetNotification(kind: .running, setAt: Date()).showsDetail)
    }

    @Test("lifetimes are Codex's constants")
    func lifetimes() {
        #expect(PetNotificationKind.running.lifetime == 3 * 60)
        #expect(PetNotificationKind.failed.lifetime == 60 * 60)
        #expect(PetNotificationKind.waiting.lifetime == 24 * 60 * 60)
        #expect(PetNotificationKind.review.lifetime == 7 * 24 * 60 * 60)
    }

    @Test("a message expires once its kind's lifetime has passed")
    func expiry() {
        let setAt = Date(timeIntervalSince1970: 1_700_000_000)
        let running = PetNotification(kind: .running, setAt: setAt)

        #expect(!running.isExpired(at: setAt.addingTimeInterval(179)))
        #expect(running.isExpired(at: setAt.addingTimeInterval(180)))

        let review = PetNotification(kind: .review, setAt: setAt)
        #expect(!review.isExpired(at: setAt.addingTimeInterval(6 * 24 * 60 * 60)))
    }

    @Test("a body replaces the fallback; blank ones do not")
    func bodies() {
        let setAt = Date()
        let named = PetNotification(kind: .waiting, body: "Bash", setAt: setAt)
        #expect(named.body == "Bash")
        #expect(named.showsDetail)

        #expect(PetNotification(kind: .waiting, body: "   ", setAt: setAt).body == "Needs input")
        #expect(PetNotification(kind: .waiting, body: nil, setAt: setAt).body == "Needs input")

        // A body identical to the label is the one-line case again.
        #expect(!PetNotification(kind: .waiting, body: "Needs input", setAt: setAt).showsDetail)
    }

    @Test("agent states map onto the four kinds")
    func stateMapping() {
        #expect(PetNotificationKind.forState(.running) == .running)
        #expect(PetNotificationKind.forState(.waitingInput) == .waiting)
        #expect(PetNotificationKind.forState(.waitingApproval) == .waiting)
        #expect(PetNotificationKind.forState(.completed) == .review)
        #expect(PetNotificationKind.forState(.failed) == .failed)

        // Idle has nothing to say; neither do states that are not real work.
        #expect(PetNotificationKind.forState(.idle) == nil)
        #expect(PetNotificationKind.forState(.paused) == nil)
        #expect(PetNotificationKind.forState(.unknown) == nil)
    }
}
