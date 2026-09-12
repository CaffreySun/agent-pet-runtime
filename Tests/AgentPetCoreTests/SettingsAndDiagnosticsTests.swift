import Foundation
import Testing
@testable import AgentPetCore

@Suite("App configuration")
struct AppConfigTests {

    private func store() -> AppConfigStore {
        AppConfigStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-config-\(UUID().uuidString)/config.json"))
    }

    @Test("defaults are safe")
    func defaults() {
        let config = AppConfig()
        // The design is explicit: software that edits agent configuration
        // without being asked is software the user cannot trust.
        #expect(!config.agents.autoConfigureNewAgents)
        #expect(config.pet.animationEnabled)
        #expect(config.pet.respectsReduceMotion)
        #expect(config.diagnostics.loggingEnabled == false)
    }

    @Test("a missing config file yields defaults rather than an error")
    func missingFileYieldsDefaults() {
        #expect(store().load() == AppConfig())
    }

    @Test("settings round-trip through disk")
    func roundTrip() throws {
        let store = store()
        var config = AppConfig()
        config.pet.defaultPetID = "clippy"
        config.pet.alwaysOnTop = false
        config.agents.autoConfigureNewAgents = true
        try store.save(config)

        #expect(store.load() == config)
    }

    @Test("a config from a future schema is ignored rather than half-applied")
    func futureSchemaIgnored() throws {
        let store = store()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var future = AppConfig()
        future.schemaVersion = AppConfig.currentSchemaVersion + 5
        future.pet.defaultPetID = "something-we-do-not-understand"
        try JSONEncoder().encode(future).write(to: store.url)

        #expect(store.load() == AppConfig(), "a newer config should fall back to defaults")
    }

    @Test("a corrupt config file yields defaults")
    func corruptFileYieldsDefaults() throws {
        let store = store()
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not json".utf8).write(to: store.url)
        #expect(store.load() == AppConfig())
    }
}

@Suite("Transition log")
struct TransitionLogTests {

    private func activity(_ state: AgentState, agent: String = "claude-code",
                          session: String = "s1", at: Date = Date()) -> AgentActivity {
        AgentActivity(
            agentID: agent, sessionID: session, state: state,
            confidence: EventConfidence(level: .high, source: "test"),
            startedAt: at, updatedAt: at, enteredStateAt: at
        )
    }

    @Test("a state change is recorded")
    func recordsTransitions() {
        let log = TransitionLog()
        log.record(activity(.running))
        log.record(activity(.waitingInput))

        #expect(log.transitions.count == 2)
        #expect(log.transitions[0].to == "running")
        #expect(log.transitions[0].from == nil)
        #expect(log.transitions[1].from == "running")
        #expect(log.transitions[1].to == "waitingInput")
    }

    @Test("a repeated identical state is not recorded")
    func ignoresRepeats() {
        let log = TransitionLog()
        for _ in 0..<50 { log.record(activity(.running)) }
        #expect(log.transitions.count == 1, "repeats would crowd out real transitions")
    }

    @Test("sessions are tracked independently")
    func perSession() {
        let log = TransitionLog()
        log.record(activity(.running, session: "a"))
        log.record(activity(.waitingInput, session: "b"))
        log.record(activity(.completed, session: "a"))

        #expect(log.transitions.count == 3)
        #expect(log.transitions[2].sessionID == "a")
        #expect(log.transitions[2].from == "running")
    }

    @Test("the log is bounded")
    func bounded() {
        let log = TransitionLog(limit: 10)
        let states: [AgentState] = [.running, .waitingInput, .completed, .idle, .failed]
        for index in 0..<100 {
            log.record(activity(states[index % states.count], session: "s\(index)"))
        }
        #expect(log.transitions.count <= 10)
    }

    @Test("forgetting a session lets it be recorded afresh")
    func forgetSession() {
        let log = TransitionLog()
        log.record(activity(.running))
        log.forget(sessionKey: SessionKey(agentID: "claude-code", sessionID: "s1"))
        log.record(activity(.running))
        #expect(log.transitions.count == 2)
    }
}

@Suite("Diagnostics bundle")
struct DiagnosticsBundleTests {

    private func sample() -> DiagnosticsBundle {
        DiagnosticsBundle(
            app: DiagnosticsBundle.AppInfo(version: "0.1.0", macOSVersion: "15.7.9", architecture: "arm64"),
            bridge: DiagnosticsBundle.BridgeSummary(
                isListening: true, socketPath: "/tmp/bridge.sock",
                eventsReceived: 12, malformedFrames: 1
            ),
            pets: [DiagnosticsBundle.PetSummary(
                id: "clippy", displayName: "Clippy",
                profile: "openAICodexV1", compatibilityWarningCount: 2
            )],
            agents: [DiagnosticsBundle.AgentSummary(
                agentID: "claude-code", detected: true, executablePath: "/usr/local/bin/claude",
                version: "2.1.268", integrationStatus: "configured", health: "Connected",
                hookCount: 7, lastEventAt: Date(timeIntervalSince1970: 1_700_000_000)
            )],
            transitions: [StateTransition(
                at: Date(timeIntervalSince1970: 1_700_000_000), agentID: "claude-code",
                sessionID: "s1", from: "running", to: "completed",
                confidence: "high", source: "claude-code.hook.Stop"
            )],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    @Test("the bundle serialises to JSON")
    func serialises() throws {
        let data = try sample().json()
        #expect((try? JSONSerialization.jsonObject(with: data)) != nil)
    }

    @Test("the exported bundle carries nothing the design forbids")
    func noForbiddenContent() throws {
        let text = String(decoding: try sample().json(), as: UTF8.self).lowercased()
        for forbidden in ["api_key", "apikey", "bearer ", "sk-", "oauth", "password", "credential"] {
            #expect(!text.contains(forbidden), "diagnostics contain '\(forbidden)'")
        }
    }

    @Test("the app info reports a real architecture")
    func architecture() {
        let architecture = DiagnosticsBundle.currentArchitecture()
        #expect(!architecture.isEmpty)
        #expect(architecture != "unknown")
    }

    @Test("currentAppInfo does not crash outside a bundle")
    func appInfoOutsideBundle() {
        // Run via `swift run` there is no Info.plist, so the version falls back.
        let info = DiagnosticsBundle.currentAppInfo()
        #expect(!info.version.isEmpty)
        #expect(info.macOSVersion.contains("."))
    }
}
