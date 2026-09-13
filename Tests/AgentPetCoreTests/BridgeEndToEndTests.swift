import Foundation
import Testing
@testable import AgentPetCore

/// Thread-safe collector for envelopes arriving on the server's own thread.
private final class EnvelopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [BridgeEnvelope] = []
    private var diagnostics: [String] = []

    func add(_ envelope: BridgeEnvelope) {
        lock.lock(); defer { lock.unlock() }
        storage.append(envelope)
    }

    func addDiagnostic(_ message: String) {
        lock.lock(); defer { lock.unlock() }
        diagnostics.append(message)
    }

    var envelopes: [BridgeEnvelope] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return diagnostics
    }
}

/// Locates the compiled shim, which is the whole point of these tests: the
/// boundary between the app and a real agent is the *binary*, so exercising an
/// in-process stand-in would prove nothing about argument parsing, socket
/// framing, or process-parent detection.
enum ShimBinary {
    static var path: String? {
        // Tests run from the package root's .build directory; walk up to find it.
        var directory = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 {
            directory.deleteLastPathComponent()
            for configuration in ["debug", "release"] {
                let candidate = directory
                    .appendingPathComponent(".build/\(configuration)/agentpet-hook")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate.path
                }
            }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
                break
            }
        }
        return nil
    }
}

@Suite("Bridge end to end", .enabled(if: ShimBinary.path != nil))
struct BridgeEndToEndTests {

    private static let socketCounter = Counter()

    /// `/tmp` rather than `NSTemporaryDirectory()`: the per-user temp directory
    /// path (`/var/folders/.../T/`) plus a unique name overflows
    /// `sockaddr_un.sun_path`, which `BridgeSocketLocation.validate` rightly
    /// refuses.
    private func makeServer(_ box: EnvelopeBox) throws -> (BridgeServer, URL) {
        let socket = URL(fileURLWithPath: "/tmp/ap-\(getpid())-\(Self.socketCounter.next()).sock")
        let server = BridgeServer(
            socketURL: socket,
            handler: { box.add($0) },
            diagnostic: { box.addDiagnostic($0) }
        )
        try server.start()
        return (server, socket)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    /// Runs the shim the way an agent would: argv plus a payload on stdin.
    ///
    /// The spool is always redirected to a throwaway directory, so a test that
    /// deliberately runs the shim with no runtime listening cannot leave
    /// files in the user's real Application Support directory.
    @discardableResult
    private func runShim(
        socket: URL,
        agent: String,
        event: String,
        payload: String,
        spool: URL? = nil,
        extraArguments: [String] = []
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ShimBinary.path!)
        process.arguments = ["--agent", agent, "--event", event] + extraArguments

        let spoolDirectory = spool ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-e2e-spool-\(UUID().uuidString)")
        var environment = ProcessInfo.processInfo.environment
        environment["AGENTPET_SOCKET"] = socket.path
        environment["AGENTPET_SPOOL"] = spoolDirectory.path
        process.environment = environment

        let input = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func waitForEnvelopes(_ box: EnvelopeBox, count: Int, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if box.envelopes.count >= count { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return box.envelopes.count >= count
    }

    @Test("a payload sent by the real shim arrives as a usable agent event")
    func fullRoundTrip() async throws {
        let box = EnvelopeBox()
        let (server, socket) = try makeServer(box)
        defer { server.stop() }

        let status = try runShim(
            socket: socket,
            agent: "claude-code",
            event: "PreToolUse",
            payload: #"{"session_id":"sess-42","cwd":"/tmp/project","tool_name":"Bash"}"#
        )
        // The contract that matters most: a hook must never disturb the agent.
        #expect(status == 0)

        #expect(await waitForEnvelopes(box, count: 1), "no envelope arrived")

        let envelope = try #require(box.envelopes.first)
        #expect(envelope.agentID == "claude-code")
        #expect(envelope.eventName == "PreToolUse")
        #expect(box.messages.isEmpty, "diagnostics: \(box.messages)")

        // The payload must survive untouched.
        #expect(envelope.payloadUTF8?.contains("sess-42") == true)

        // The shim's parent is this test process, which is standing in for the
        // agent — proving the correlation handle is real.
        #expect(envelope.proc?.ppid == getpid())

        let events = EventNormalizer(profiles: AgentProfiles.all).normalize(envelope)
        let event = try #require(events.first)
        #expect(event.kind == .working)
        #expect(event.sessionID == "sess-42")
    }

    @Test("many events in sequence all arrive, none lost or duplicated")
    func manyEvents() async throws {
        let box = EnvelopeBox()
        let (server, socket) = try makeServer(box)
        defer { server.stop() }

        let count = 25
        var elapsed: [Double] = []
        for index in 0..<count {
            let started = Date()
            try runShim(
                socket: socket,
                agent: "claude-code",
                event: "PreToolUse",
                payload: #"{"session_id":"s\#(index)","cwd":"/tmp/p"}"#
            )
            elapsed.append(Date().timeIntervalSince(started) * 1000)
        }

        // This is the number that decides whether the bridge is acceptable in
        // production: it is time added to the user's agent, once per tool call.
        let sorted = elapsed.sorted()
        print(String(format: "shim latency with a live runtime: "
                     + "P50=%.2fms P95=%.2fms max=%.2fms (n=%d)",
                     sorted[sorted.count / 2],
                     sorted[Int(Double(sorted.count) * 0.95)],
                     sorted.last ?? 0,
                     count))

        #expect(await waitForEnvelopes(box, count: count, timeout: 10))
        let sessions = Set(box.envelopes.compactMap(\.payloadUTF8))
        #expect(sessions.count == count, "expected \(count) distinct payloads, got \(sessions.count)")
    }

    @Test("shim events drive the activity engine end to end")
    func drivesEngine() async throws {
        let box = EnvelopeBox()
        let (server, socket) = try makeServer(box)
        defer { server.stop() }

        try runShim(socket: socket, agent: "claude-code", event: "PreToolUse",
                    payload: #"{"session_id":"a","cwd":"/tmp/p"}"#)
        try runShim(socket: socket, agent: "claude-code", event: "PermissionRequest",
                    payload: #"{"session_id":"a","cwd":"/tmp/p"}"#)
        try runShim(socket: socket, agent: "claude-code", event: "Stop",
                    payload: #"{"session_id":"a","cwd":"/tmp/p"}"#)

        #expect(await waitForEnvelopes(box, count: 3, timeout: 10))

        let clock = ManualActivityClock()
        let engine = ActivityEngine(clock: clock)
        let normalizer = EventNormalizer(profiles: AgentProfiles.all)

        var observed: [AgentState] = []
        for envelope in box.envelopes {
            for event in normalizer.normalize(envelope) { engine.ingest(event) }
            if let state = engine.currentFocus()?.state { observed.append(state) }
        }

        #expect(observed.contains(.running))
        #expect(observed.contains(.waitingApproval))
        #expect(observed.contains(.completed))
    }

    @Test("the shim exits 0 even when no runtime is listening")
    func exitsZeroWithoutRuntime() throws {
        // The single most important property: a stopped pet must be invisible
        // to the agent, never an error.
        let dead = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-does-not-exist-\(UUID().uuidString).sock")

        let status = try runShim(socket: dead, agent: "claude-code", event: "Stop", payload: "{}")
        #expect(status == 0)
    }

    @Test("an event that outlives the runtime is written down, not lost")
    func undeliveredEventIsSpooled() throws {
        // The upgrade path: `brew upgrade --cask` stops the old app, the
        // hooks keep firing into nothing, and the next launch has to find out
        // what it missed.
        let spool = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-e2e-spool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: spool) }

        let dead = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-does-not-exist-\(UUID().uuidString).sock")
        let status = try runShim(
            socket: dead, agent: "claude-code", event: "PreToolUse",
            payload: #"{"session_id":"mid-turn","cwd":"/tmp/p","tool_name":"Bash","tool_input":{"command":"secret"}}"#,
            spool: spool
        )
        #expect(status == 0, "the agent still sees a clean exit")
        #expect(EventSpool.pendingCount(in: spool) == 1)

        // ...and the next launch gets a usable event out of it.
        var replayed: [BridgeEnvelope] = []
        EventSpool.drain(from: spool) { replayed.append($0) }
        let envelope = try #require(replayed.first)
        let payload = try #require(envelope.payloadUTF8)
        // The key name survives only as an omission marker; the command the
        // user's agent ran does not survive at all.
        #expect(!payload.contains("secret"),
                "the spool is on disk, so it is held to the log's allowlist")
        #expect(payload.contains("tool_name"))

        let engine = ActivityEngine(clock: ManualActivityClock())
        for event in EventNormalizer(profiles: AgentProfiles.all).normalize(envelope) {
            engine.ingest(event)
        }
        #expect(engine.currentFocus()?.state == .running)
        #expect(engine.currentFocus()?.sessionID == "mid-turn")
    }

    /// Runs the shim in status-line mode with stdout captured — the whole
    /// point of the tap is that the user's status line comes back out.
    private func runStatusLineShim(
        socket: URL,
        original: String?,
        stdin: String,
        spool: URL
    ) throws -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ShimBinary.path!)
        let encoded = Data((original ?? "").utf8).base64EncodedString()
        process.arguments = ["--agent", "claude-code", "--statusline", "--original", encoded]

        var environment = ProcessInfo.processInfo.environment
        environment["AGENTPET_SOCKET"] = socket.path
        environment["AGENTPET_SPOOL"] = spool.path
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        input.fileHandleForWriting.closeFile()

        let out = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out, as: UTF8.self))
    }

    @Test("the status-line tap reports, then runs the user's own command")
    func statusLineTap() async throws {
        let box = EnvelopeBox()
        let (server, socket) = try makeServer(box)
        defer { server.stop() }

        let spool = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-e2e-spool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: spool) }

        // A status line shaped the way the installed build documents it, with
        // the fields the app must not keep mixed in.
        let payload = """
        {
          "session_id": "6b1e4c2a-0000-0000-0000-000000000000",
          "session_name": "payment refactor",
          "transcript_path": "/Users/someone/.claude/projects/p/6b1e4c2a.jsonl",
          "context_window": {
            "used_percentage": 61.5,
            "context_window_size": 200000,
            "total_input_tokens": 123000
          },
          "workspace": { "repo": { "name": "checkout" } },
          "cost": { "total_cost_usd": 3.5 }
        }
        """
        let hud = "cat > /dev/null; printf 'HUD-OK'"
        let result = try runStatusLineShim(socket: socket, original: hud, stdin: payload, spool: spool)

        #expect(result.status == 0)
        #expect(result.stdout == "HUD-OK", "the user's status line must come through untouched")

        #expect(await waitForEnvelopes(box, count: 1))
        let envelope = try #require(box.envelopes.first)
        #expect(envelope.eventName == "Statusline")
        let reduced = try #require(envelope.payloadUTF8)
        #expect(reduced.contains("61.5"))
        #expect(reduced.contains("payment refactor"))
        #expect(reduced.contains("checkout"))
        #expect(!reduced.contains("transcript_path"),
                "the status payload carries paths and costs; the socket gets the allowlist")
        #expect(!reduced.contains("cost"))

        let events = EventNormalizer(profiles: AgentProfiles.all).normalize(envelope)
        let event = try #require(events.first)
        #expect(event.kind == .contextUpdate)
        #expect(event.context?.usedPercent == 61.5)
        #expect(event.context?.sessionName == "payment refactor")
    }

    @Test("the wrapped status line still runs when the runtime is not")
    func statusLineWithoutRuntime() throws {
        // The worst possible failure mode of this feature is a pet that
        // breaks the user's prompt when the pet is not even running.
        let spool = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-e2e-spool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: spool) }
        let dead = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-does-not-exist-\(UUID().uuidString).sock")

        let result = try runStatusLineShim(
            socket: dead, original: "cat > /dev/null; printf 'HUD-OK'; exit 7",
            stdin: #"{"session_id":"x"}"#, spool: spool
        )
        #expect(result.stdout == "HUD-OK")
        #expect(result.status == 7, "Claude Code must see the wrapped command's own exit code")
        #expect(EventSpool.pendingCount(in: spool) == 0,
                "a status line renders constantly; spooling it would fill the spool with duplicates")
    }

    @Test("nothing is spooled while the runtime is listening")
    func liveEventsAreNotSpooled() async throws {
        let box = EnvelopeBox()
        let (server, socket) = try makeServer(box)
        defer { server.stop() }

        let spool = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-e2e-spool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: spool) }

        try runShim(socket: socket, agent: "claude-code", event: "Stop",
                    payload: #"{"session_id":"a"}"#, spool: spool)

        #expect(await waitForEnvelopes(box, count: 1))
        #expect(EventSpool.pendingCount(in: spool) == 0,
                "a delivered event must not also be waiting for the next launch")
    }

    @Test("an empty payload is delivered rather than dropped")
    func emptyPayload() async throws {
        let box = EnvelopeBox()
        let (server, socket) = try makeServer(box)
        defer { server.stop() }

        try runShim(socket: socket, agent: "codex", event: "turn-ended", payload: "")

        #expect(await waitForEnvelopes(box, count: 1))
        let envelope = try #require(box.envelopes.first)
        #expect(envelope.rawPayload.isEmpty)
    }

    @Test("a large payload survives intact")
    func largePayload() async throws {
        let box = EnvelopeBox()
        let (server, socket) = try makeServer(box)
        defer { server.stop() }

        let blob = String(repeating: "x", count: 200_000)
        try runShim(socket: socket, agent: "claude-code", event: "PreToolUse",
                    payload: #"{"session_id":"big","cwd":"/tmp/p","blob":"\#(blob)"}"#)

        #expect(await waitForEnvelopes(box, count: 1))
        let envelope = try #require(box.envelopes.first)
        #expect(envelope.rawPayload.count > 200_000, "payload was truncated")
    }

    @Test("garbage on the socket does not take the bridge down")
    func malformedFrameIsIsolated() async throws {
        let box = EnvelopeBox()
        let (server, sock) = try makeServer(box)
        defer { server.stop() }

        // Write nonsense directly, then a good event through the real shim.
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd >= 0 {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let pathBytes = Array(sock.path.utf8CString)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                pathBytes.withUnsafeBytes { source in destination.copyBytes(from: source) }
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if connected == 0 {
                _ = "this is not json\n".withCString { write(fd, $0, strlen($0)) }
            }
            close(fd)
        }

        try runShim(socket: sock, agent: "claude-code", event: "Stop",
                    payload: #"{"session_id":"after-garbage"}"#)

        #expect(await waitForEnvelopes(box, count: 1), "the bridge stopped serving after bad input")
        #expect(box.messages.contains { $0.contains("unreadable") })
    }
}
