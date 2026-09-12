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
    @discardableResult
    private func runShim(
        socket: URL,
        agent: String,
        event: String,
        payload: String,
        extraArguments: [String] = []
    ) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ShimBinary.path!)
        process.arguments = ["--agent", agent, "--event", event] + extraArguments

        var environment = ProcessInfo.processInfo.environment
        environment["AGENTPET_SOCKET"] = socket.path
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
