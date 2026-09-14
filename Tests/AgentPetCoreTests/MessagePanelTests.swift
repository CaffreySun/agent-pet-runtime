import Foundation
import Testing
@testable import AgentPetCore

/// The rows drawn beside the pet: what goes in them, in what order, and what
/// they refuse to show.
@Suite("Message panel")
struct MessagePanelTests {

    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private var config: MessagePanelConfig { MessagePanelConfig() }

    private func activity(
        _ agent: String = "claude-code",
        session: String,
        state: AgentState,
        at offset: TimeInterval = 0,
        tool: String? = nil,
        context: SessionContext? = nil,
        title: String? = nil,
        detail: String? = nil,
        cwd: String? = "/Users/someone/projects/agent-pet-runtime"
    ) -> AgentActivity {
        AgentActivity(
            agentID: agent,
            sessionID: session,
            state: state,
            confidence: EventConfidence(level: .high, source: "test"),
            title: title,
            detail: detail,
            toolName: tool,
            focusTarget: cwd.map { .openingDirectory(URL(fileURLWithPath: $0)) },
            context: context,
            startedAt: origin.addingTimeInterval(offset),
            updatedAt: origin.addingTimeInterval(offset),
            enteredStateAt: origin.addingTimeInterval(offset)
        )
    }

    @Test("the session suffix is the last six characters")
    func suffix() {
        #expect(MessagePanel.suffix(of: "f9602f46-ef52-4407-b3f0-9672904f833e") == "4f833e")
        // A short session id — Codex's fixed ids, or a fallback — is shown as
        // it is rather than padded with something invented.
        #expect(MessagePanel.suffix(of: "codex-default") == "efault")
        #expect(MessagePanel.suffix(of: "abc") == "abc")
    }

    @Test("sessions of one agent stay together, blocked first")
    func grouping() {
        let ranked = [
            activity(session: "aaaaaa-1", state: .waitingApproval),
            activity("codex", session: "bbbbbb-2", state: .running),
            activity(session: "cccccc-3", state: .running),
        ]
        let panel = MessagePanel.build(
            ranked: ranked, focusedID: nil, agentNames: [:], config: config, now: origin
        )
        #expect(panel.rows.map(\.agentID) == ["claude-code", "claude-code", "codex"],
                "the same agent's sessions must be adjacent")
        #expect(panel.rows.map(\.sessionSuffix) == ["aaaa-1", "cccc-3", "bbbb-2"])
    }

    @Test("the task title prefers what the user named, then the repo, then the directory")
    func taskTitle() {
        let named = activity(session: "a", state: .running, context: SessionContext(
            sessionName: "payment refactor", projectName: "checkout", capturedAt: origin
        ))
        #expect(MessagePanel.taskTitle(for: named) == "payment refactor")

        let repo = activity(session: "a", state: .running, context: SessionContext(
            projectName: "checkout", capturedAt: origin
        ))
        #expect(MessagePanel.taskTitle(for: repo) == "checkout")

        let plain = activity(session: "a", state: .running)
        #expect(MessagePanel.taskTitle(for: plain) == "agent-pet-runtime")
    }

    @Test("a tool is current only while the session is working")
    func toolVisibility() {
        let working = activity(session: "a", state: .running, tool: "Bash")
        let finished = activity(session: "b", state: .completed, tool: "Bash")
        let panel = MessagePanel.build(
            ranked: [working, finished], focusedID: nil, agentNames: [:], config: config, now: origin
        )
        #expect(panel.rows.first { $0.sessionSuffix == "a" }?.tool == "Bash")
        #expect(panel.rows.first { $0.sessionSuffix == "b" }?.tool == nil,
                "a tool the session has finished with is not the one it is using")
    }

    @Test("the row speaks the same vocabulary the pet always has")
    func messageWording() {
        let panel = MessagePanel.build(
            ranked: [
                activity(session: "a", state: .running, title: "a prompt the user typed"),
                activity(session: "b", state: .waitingApproval, title: "Write"),
                activity(session: "c", state: .completed, detail: "Done — three files changed."),
                activity(session: "d", state: .failed, title: "context limit"),
            ],
            focusedID: nil, agentNames: [:], config: config, now: origin
        )

        let running = panel.rows.first { $0.sessionSuffix == "a" }?.message
        #expect(running?.label == "Running")
        #expect(running?.body == nil,
                "the running summary may be the user's prompt, and that never goes on screen")

        #expect(panel.rows.first { $0.sessionSuffix == "b" }?.message?.body == "Write")
        #expect(panel.rows.first { $0.sessionSuffix == "c" }?.message?.body == "Done — three files changed.")
        #expect(panel.rows.first { $0.sessionSuffix == "d" }?.message?.label == "Blocked")
    }

    @Test("an idle row leaves once nothing has been heard from it for a while")
    func idleRowsExpire() {
        let idle = activity(session: "a", state: .idle)
        let fresh = MessagePanel.build(
            ranked: [idle], focusedID: nil, agentNames: [:], config: config,
            now: origin.addingTimeInterval(60)
        )
        #expect(fresh.rows.count == 1, "a session that just finished is still worth a row")

        let stale = MessagePanel.build(
            ranked: [idle], focusedID: nil, agentNames: [:], config: config,
            now: origin.addingTimeInterval(MessagePanel.idleRowLifetime + 1)
        )
        #expect(stale.rows.isEmpty,
                "a killed terminal never sends SessionEnd; its row must not float forever")
    }

    @Test("a status line keeps an idle row alive, because the session plainly still exists")
    func contextKeepsIdleRowAlive() {
        let live = activity(session: "a", state: .idle, context: SessionContext(
            usedPercent: 12, capturedAt: origin.addingTimeInterval(3000)
        ))
        let panel = MessagePanel.build(
            ranked: [live], focusedID: nil, agentNames: [:], config: config,
            now: origin.addingTimeInterval(3060)
        )
        #expect(panel.rows.count == 1)
    }

    @Test("a panel that is not always visible waits for something to happen")
    func alwaysVisibleOff() {
        let idle = activity(session: "a", state: .idle)
        let quiet = MessagePanelConfig(alwaysVisible: false)

        #expect(MessagePanel.build(
            ranked: [idle], focusedID: nil, agentNames: [:], config: quiet, now: origin
        ).rows.isEmpty)

        let working = activity(session: "b", state: .running)
        let busy = MessagePanel.build(
            ranked: [idle, working], focusedID: nil, agentNames: [:], config: quiet, now: origin
        )
        #expect(busy.rows.count == 2, "once it is up, it shows every session")
    }

    @Test("the row the pet is showing is marked")
    func focusedRow() {
        let focused = activity(session: "a", state: .running)
        let other = activity(session: "b", state: .running, at: 1)
        let panel = MessagePanel.build(
            ranked: [focused, other], focusedID: other.id, agentNames: ["claude-code": "Claude Code"],
            config: config, now: origin
        )
        #expect(panel.rows.first { $0.sessionSuffix == "b" }?.isFocused == true)
        #expect(panel.rows.first { $0.sessionSuffix == "a" }?.isFocused == false)
        #expect(panel.rows.first?.agentName == "Claude Code")
    }

    @Test("usage comes from Claude Code's number when it gives one")
    func usageFraction() {
        let percent = SessionContext(usedPercent: 72.5, totalTokens: 1, windowSize: 1, capturedAt: origin)
        #expect(MessagePanelLayoutUsageCheck.fraction(percent) == 0.725)

        // No percentage, but both ingredients: work it out.
        let computed = SessionContext(totalTokens: 50_000, windowSize: 200_000, capturedAt: origin)
        #expect(MessagePanelLayoutUsageCheck.fraction(computed) == 0.25)

        // Tokens without a window are not a fraction, and must not be guessed
        // into one.
        let unknownWindow = SessionContext(totalTokens: 50_000, capturedAt: origin)
        #expect(MessagePanelLayoutUsageCheck.fraction(unknownWindow) == nil)

        // Overrun is clamped for drawing, not hidden.
        let over = SessionContext(usedPercent: 140, capturedAt: origin)
        #expect(MessagePanelLayoutUsageCheck.fraction(over) == 1)
    }
}

/// The usage arithmetic lives in the app's layout code (it is about drawing),
/// so the parts worth testing are reached through this shim rather than
/// duplicating the rule in the core.
enum MessagePanelLayoutUsageCheck {
    static func fraction(_ context: SessionContext) -> Double? {
        if let percent = context.usedPercent {
            return min(max(percent / 100, 0), 1)
        }
        guard let tokens = context.totalTokens, let window = context.windowSize, window > 0 else {
            return nil
        }
        return min(max(Double(tokens) / Double(window), 0), 1)
    }
}

@Suite("Message panel configuration")
struct MessagePanelConfigTests {

    @Test("a config written before the panel existed still loads")
    func backwardCompatible() throws {
        // The file on disk from any previous release has no `messagePanel`
        // key. Synthesised decoding would fail the whole config, and the store
        // refuses to half-read a file — so every existing user would silently
        // be back on defaults.
        let json = """
        {
          "schemaVersion": 1,
          "pet": { "defaultPetID": "clippit", "animationEnabled": false,
                   "alwaysOnTop": true, "respectsReduceMotion": true },
          "agents": { "enabledAgents": [], "autoConfigureNewAgents": false },
          "diagnostics": { "loggingEnabled": true, "transitionHistoryLimit": 50 }
        }
        """
        let config = try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8))

        #expect(config.pet.defaultPetID == "clippit", "the user's choices must survive")
        #expect(config.diagnostics.loggingEnabled)
        #expect(config.messagePanel == MessagePanelConfig(), "the new section defaults")
        #expect(config.messagePanel.items.map(\.kind) == MessagePanelConfig.Kind.allCases)
        #expect(config.messagePanel.alwaysVisible)
    }

    @Test("a config round-trips through the store, new items joining at the end")
    func roundTrip() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-config-\(UUID().uuidString)/config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        var config = AppConfig()
        config.messagePanel.alwaysVisible = false
        config.messagePanel.items = [.init(.context), .init(.agent, isEnabled: false)]
        try AppConfigStore(url: url).save(config)

        let reloaded = AppConfigStore(url: url).load()
        #expect(!reloaded.messagePanel.alwaysVisible)
        // The user's two entries stay where they put them, switched off as
        // they left them; every kind they have never seen joins the end.
        #expect(Array(reloaded.messagePanel.items.prefix(2)) == config.messagePanel.items)
        #expect(reloaded.messagePanel.items.dropFirst(2).map(\.kind)
            == MessagePanelConfig.Kind.allCases.filter { $0 != .context && $0 != .agent })
        #expect(reloaded.messagePanel.items.dropFirst(2).allSatisfy { $0.isEnabled })
    }
}

@Suite("Pet introduction")
struct GreetingTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("the introduction names the pet, and lasts Codex's eight seconds")
    func introduction() {
        let greeting = MessagePanel.Greeting.introduction(petName: "Clippy")
        #expect(greeting.title == "Hi, I'm Clippy")
        #expect(greeting.body == "I'm here to help keep your sessions moving")

        // Codex's own lifetime (`wd = 8e3`): still there a second short of it,
        // gone at it.
        #expect(!greeting.isExpired(shownAt: now, now: now.addingTimeInterval(7.9)))
        #expect(greeting.isExpired(shownAt: now, now: now.addingTimeInterval(8)))
    }

    @Test("the introduction is a row of its own, with nothing a session has")
    func introductionIsItsOwnRow() {
        let empty = MessagePanel.build(
            ranked: [], focusedID: nil, config: MessagePanelConfig(), now: now
        )
        #expect(empty.isEmpty, "no sessions and nothing to say is an empty panel")

        // It has to appear even when no session does — that is the moment the
        // pet introduces itself.
        let greeting = MessagePanel.build(
            ranked: [], focusedID: nil, config: MessagePanelConfig(), now: now,
            greeting: .introduction(petName: "Clippy")
        )
        #expect(greeting.rows.count == 1)
        #expect(greeting.rows.first?.message?.label == "Hi, I'm Clippy")
        #expect(greeting.rows.first?.agentName == "")
        #expect(greeting.rows.first?.sessionSuffix == "")
    }

    @Test("a hidden panel still says hello")
    func introductionOutranksAlwaysVisible() {
        // `alwaysVisible = false` means "only while something is happening".
        // The pet introducing itself is something happening.
        var config = MessagePanelConfig()
        config.alwaysVisible = false
        let greeting = MessagePanel.build(
            ranked: [], focusedID: nil, config: config, now: now,
            greeting: .introduction(petName: "Clippy")
        )
        #expect(greeting.rows.count == 1)
    }
}

@Suite("Session context")
struct SessionContextTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a status-line payload becomes context, and nothing else does")
    func parsing() {
        let context = SessionContext.fromStatusPayload([
            "session_id": "abc",
            "session_name": "payment refactor",
            "used_percentage": 42.0,
            "window": 200_000,
            "tokens": 84_000,
            "project": "checkout",
            // Anything the shim did not reduce away is ignored, not kept.
            "transcript_path": "/Users/someone/.claude/projects/x/y.jsonl",
            "cost": ["total_cost_usd": 1.23],
        ], at: now)

        #expect(context?.usedPercent == 42)
        #expect(context?.totalTokens == 84_000)
        #expect(context?.windowSize == 200_000)
        #expect(context?.sessionName == "payment refactor")
        #expect(context?.projectName == "checkout")

        // A session before its first message reports nulls; that is no context,
        // not an empty one.
        #expect(SessionContext.fromStatusPayload(["session_id": "abc"], at: now) == nil)
    }

    @Test("a whole number too large to be one is dropped, not fatal")
    func oversizedIntegersAreIgnored() {
        // `JSONSerialization` returns a Double for a JSON integer beyond
        // Int64, and `Int(Double)` traps. A frame carrying one arrived over
        // the socket and took the whole app down with it — the one thing a
        // malformed frame must never do.
        let context = SessionContext.fromStatusPayload([
            "tokens": 9_223_372_036_854_775_808.0,   // 2^63, one past Int.max
            "window": 1e19,                          // and past anything at all
            "used_percentage": 42.0,
        ], at: now)

        #expect(context?.totalTokens == nil)
        #expect(context?.windowSize == nil)
        #expect(context?.usedPercent == 42, "the rest of the reading is still worth showing")
    }

    @Test("model, cost, and limits read the way a person would write them")
    func labels() {
        let full = SessionContext(
            modelName: "Opus 4.6", effortLevel: "high", costUSD: 3.4216,
            fiveHourPercent: 41.4, sevenDayPercent: 12.5, capturedAt: now
        )
        #expect(full.modelLabel == "Opus 4.6 · high")
        #expect(full.costLabel == "$3.42")
        #expect(full.limitsLabel == "5h 41% · 7d 13%")

        // A model with no effort setting says just its name.
        let plain = SessionContext(modelName: "deepseek-flash", capturedAt: now)
        #expect(plain.modelLabel == "deepseek-flash")
        #expect(plain.costLabel == nil)
        #expect(plain.limitsLabel == nil)

        // Past ten dollars the cents are noise.
        #expect(SessionContext(costUSD: 42.7, capturedAt: now).costLabel == "$42.7")

        // A session before any API response has no cost and no limits, and
        // must not show "$0.00" as if it had been measured.
        #expect(SessionContext(usedPercent: 5, capturedAt: now).costLabel == nil)

        // One window known is still worth showing.
        #expect(SessionContext(sevenDayPercent: 61.2, capturedAt: now).limitsLabel == "7d 61%")
    }

    @Test("a later reading fills in what it knows and keeps what it does not")
    func merging() {
        let named = SessionContext(sessionName: "payment refactor", capturedAt: now)
        let reading = SessionContext(usedPercent: 60, capturedAt: now.addingTimeInterval(5))

        let merged = named.merging(reading)
        #expect(merged.usedPercent == 60)
        #expect(merged.sessionName == "payment refactor",
                "a reading with no name must not erase the name the user gave")
        #expect(merged.capturedAt == now.addingTimeInterval(5))

        let renamed = SessionContext(sessionName: "checkout work", capturedAt: now.addingTimeInterval(9))
        #expect(merged.merging(renamed).sessionName == "checkout work")
    }
}

@Suite("Context updates in the engine")
struct ContextUpdateTests {

    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func contextEvent(
        _ context: SessionContext, session: String = "a", at offset: TimeInterval
    ) -> AgentEvent {
        AgentEvent(
            agentID: "claude-code",
            sessionID: session,
            kind: .contextUpdate,
            at: origin.addingTimeInterval(offset),
            confidence: EventConfidence(level: .high, source: "claude-code.statusline"),
            context: context
        )
    }

    @Test("an event that carries a reading is still a state change")
    func stateWinsOverContext() {
        // The bug this exists for: keying the context path on "has a context"
        // rather than on the kind meant an event carrying both was handled as
        // a reading — the session's state never moved, and it was created
        // idle instead of blocked.
        let engine = ActivityEngine(clock: ManualActivityClock(origin))
        engine.ingest(AgentEvent(
            agentID: "claude-code", sessionID: "a", kind: .waitingApproval, at: origin,
            confidence: EventConfidence(level: .high, source: "test"),
            context: SessionContext(usedPercent: 40, capturedAt: origin)
        ))

        let activity = engine.activity(for: SessionKey(agentID: "claude-code", sessionID: "a"))
        #expect(activity?.state == .waitingApproval)
        #expect(activity?.context?.usedPercent == 40)
    }

    @Test("a reading describes a session without moving it")
    func doesNotTouchState() {
        let engine = ActivityEngine(clock: ManualActivityClock(origin))
        engine.ingest(AgentEvent(
            agentID: "claude-code", sessionID: "a", kind: .working, at: origin,
            confidence: EventConfidence(level: .high, source: "test")
        ))
        let before = engine.activity(for: SessionKey(agentID: "claude-code", sessionID: "a"))

        engine.ingest(contextEvent(
            SessionContext(usedPercent: 30, capturedAt: origin.addingTimeInterval(20)), at: 20
        ))
        let after = engine.activity(for: SessionKey(agentID: "claude-code", sessionID: "a"))

        #expect(after?.context?.usedPercent == 30)
        #expect(after?.state == .running)
        #expect(after?.updatedAt == before?.updatedAt,
                "a status line rendering at the prompt must not keep a finished turn looking alive")
    }

    @Test("a reading for a session nothing else has reported brings it into view")
    func createsIdleActivity() {
        // What a restart looks like with the tap installed: no hook has fired
        // yet, but every open session is rendering its status line.
        let engine = ActivityEngine(clock: ManualActivityClock(origin))
        engine.ingest(contextEvent(
            SessionContext(usedPercent: 55, projectName: "checkout", capturedAt: origin), at: 0
        ))

        let activity = engine.activity(for: SessionKey(agentID: "claude-code", sessionID: "a"))
        #expect(activity?.state == .idle)
        #expect(activity?.context?.projectName == "checkout")

        // And a reading for a session that has since closed does not resurrect it.
        engine.ingest(AgentEvent(
            agentID: "claude-code", sessionID: "a", kind: .sessionClosed, at: origin.addingTimeInterval(1),
            confidence: EventConfidence(level: .high, source: "test")
        ))
        engine.ingest(contextEvent(SessionContext(usedPercent: 60, capturedAt: origin.addingTimeInterval(2)), at: 2))
        #expect(engine.activity(for: SessionKey(agentID: "claude-code", sessionID: "a")) != nil,
                "a closed session that starts reporting again is a real session again")
    }

    @Test("ranked sessions are the order the pet would pick them in")
    func rankedOrder() {
        let engine = ActivityEngine(clock: ManualActivityClock(origin))
        let confidence = EventConfidence(level: .high, source: "test")
        engine.ingest(AgentEvent(agentID: "claude-code", sessionID: "work", kind: .working,
                                 at: origin, confidence: confidence))
        engine.ingest(AgentEvent(agentID: "claude-code", sessionID: "blocked", kind: .waitingApproval,
                                 at: origin.addingTimeInterval(1), confidence: confidence))
        engine.ingest(AgentEvent(agentID: "claude-code", sessionID: "done", kind: .completed,
                                 at: origin.addingTimeInterval(2), confidence: confidence))

        #expect(engine.rankedActivities().map(\.sessionID) == ["blocked", "work", "done"])
    }
}
