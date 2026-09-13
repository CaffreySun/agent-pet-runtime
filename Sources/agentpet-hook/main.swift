import AgentPetCore
import Darwin
import Foundation

// agentpet-hook — the executable an agent invokes as its hook.
//
// This process sits on the agent's critical path: Claude Code runs hooks
// synchronously and waits for them, once per tool call. Every millisecond here
// is a millisecond added to the user's agent.
//
// The contract, in priority order:
//
//   1. ALWAYS exit 0. Claude Code treats a non-zero hook exit as meaningful —
//      it can block the tool call and feed stderr back to the model. A pet
//      that changes what the agent does would be a far worse bug than a pet
//      that misses an event.
//   2. Never block. If the runtime is not running, the event is written to a
//      small spool file for the next launch to replay (see EventSpool) and
//      this process exits. The trade is unchanged: a missed animation is
//      invisible, a stalled agent is not.
//   3. Never write to stdout. The agent may be parsing it.
//
// Measured cold start with Foundation linked is ~3.7ms, inside the 5ms P50
// budget. See docs/ARCHITECTURE.md §5.

let arguments = CommandLine.arguments

func value(of flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

if arguments.contains("--version") {
    print(BridgeEnvelope.defaultShimVersion)
    exit(0)
}

// The status-line tap (opt-in, installed by the manager) runs this shim as
// Claude Code's status line. Two jobs, in this order: forward a reduced copy
// of what Claude Code knows to the bridge, then run the command this shim
// displaced and hand its output through untouched. The user's prompt must look
// exactly as it did, whatever happens here.
if arguments.contains("--statusline") {
    exit(runStatusLineTap(arguments: arguments))
}

// Grok Build deliberately scans and trusts ~/.claude/settings.json, so the
// Claude Code hooks installed there also run on Grok's own hook events. Left
// unguarded they would report every Grok session as a Claude Code one.
// `GROK_HOOK_NAME` is injected by Grok's hook runner and never set by Claude
// Code itself, which makes it a reliable tell.
let declaredAgent = value(of: "--agent") ?? "unknown"
let agentID = ProcessInfo.processInfo.environment["GROK_HOOK_NAME"] != nil
    ? "grok"
    : declaredAgent

guard !agentID.isEmpty else {
    FileHandle.standardError.write(Data("agentpet-hook: --agent is required\n".utf8))
    exit(64)
}
// The event name may come from argv, or from the agent's own argument (Codex's
// notify passes one). Default rather than fail: a nameless event is still
// worth delivering if the agent id is known.
let eventName = value(of: "--event") ?? value(of: "--event-name") ?? "unknown"

// The agent passes its payload on stdin. It is forwarded verbatim — parsing it
// here would risk failing on a shape this build does not recognise, and would
// put JSON work on the critical path for no benefit.
let payload = readStandardInput()

// The shim's parent is the agent: this is the one correlation handle available
// without Accessibility permissions.
let parentPID = getppid()
let ownPID = getpid()
let tty = controllingTerminal()

let envelope = BridgeEnvelope(
    agentID: agentID,
    eventName: eventName,
    receivedAt: Date(),
    proc: BridgeProcessInfo(
        pid: ownPID,
        ppid: parentPID,
        tty: tty
    ),
    rawPayload: payload,
    shimVersion: BridgeEnvelope.defaultShimVersion
)

let socketURL = resolveSocketURL()
if !deliver(envelope, to: socketURL) {
    // Nobody was listening. The event is not lost: the next launch of the
    // runtime replays it, reduced to the fields the state machine needs.
    EventSpool.write(envelope, to: resolveSpoolURL())
}
exit(0)

// MARK: - Helpers

func readStandardInput() -> Data {
    // An interactive terminal has no hook payload behind it, and reading would
    // block until the user typed something. Someone running this by hand to see
    // what it does must not hang.
    if isatty(STDIN_FILENO) == 1 { return Data() }

    var data = Data()
    let limit = BridgeEnvelope.maximumPayloadBytes
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)

    while data.count < limit {
        // Bounded by a deadline as well as by EOF: a writer that opens the pipe
        // and then stalls must not hold the agent here.
        guard waitReadable(STDIN_FILENO, milliseconds: 20) else { break }

        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count <= 0 { break }
        data.append(contentsOf: buffer[0..<count])
    }
    return data
}

func waitReadable(_ fd: Int32, milliseconds: Int32) -> Bool {
    var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
    let ready = poll(&descriptor, 1, milliseconds)
    return ready > 0 && (descriptor.revents & Int16(POLLIN | POLLHUP)) != 0
}

/// `ttyname` returns nil for a process with no controlling terminal, which is
/// normal when an agent runs detached.
func controllingTerminal() -> String? {
    guard let pointer = ttyname(STDIN_FILENO) else { return nil }
    return String(cString: pointer)
}

// MARK: - Status-line tap

/// Runs as Claude Code's status line: reports what it can, then gets out of
/// the way of the status line the user actually configured.
///
/// Returns the exit code of the wrapped command, so this process is invisible
/// to Claude Code — it sees its own status line, with its own exit code.
func runStatusLineTap(arguments: [String]) -> Int32 {
    let input = readStandardInput()

    let agentID = value(of: "--agent") ?? "claude-code"
    if let reduced = reducedStatusPayload(input) {
        let envelope = BridgeEnvelope(
            agentID: agentID,
            eventName: "Statusline",
            receivedAt: Date(),
            proc: BridgeProcessInfo(pid: getpid(), ppid: getppid(), tty: nil),
            rawPayload: reduced
        )
        // Fire and forget, and never spool: a status line renders over and
        // over, so the next reading is a second away. Writing these down
        // would fill the spool with duplicates of a fact that is stale by
        // the time it is read back.
        _ = deliver(envelope, to: resolveSocketURL())
    }

    let encoded = value(of: "--original") ?? ""
    guard let data = Data(base64Encoded: encoded),
          let original = String(data: data, encoding: .utf8),
          !original.isEmpty
    else {
        // Nothing was displaced — either the tap was installed over a bare
        // prompt, or this copy of the command is unreadable. Either way the
        // honest output is none.
        return 0
    }

    return runWrapped(original, stdin: input)
}

/// Reduces Claude Code's status-line JSON to the handful of fields the panel
/// can use.
///
/// An allowlist, like the event log: the payload also carries the transcript
/// path, cost, and rate-limit state, and none of that belongs anywhere near
/// this app's files or its socket.
func reducedStatusPayload(_ input: Data) -> Data? {
    guard !input.isEmpty,
          let root = try? JSONSerialization.jsonObject(with: input) as? [String: Any]
    else { return nil }

    var reduced: [String: Any] = [:]
    if let sessionID = root["session_id"] as? String { reduced["session_id"] = sessionID }
    if let name = root["session_name"] as? String, !name.isEmpty { reduced["session_name"] = name }

    let window = root["context_window"] as? [String: Any]
    if let percent = window?["used_percentage"] as? NSNumber {
        reduced["used_percentage"] = percent.doubleValue
    }
    if let size = window?["context_window_size"] as? NSNumber { reduced["window"] = size.intValue }
    if let tokens = window?["total_input_tokens"] as? NSNumber { reduced["tokens"] = tokens.intValue }

    // Repository name when there is one, else the project directory: the
    // closest thing to a task title that does not require reading a transcript.
    let workspace = root["workspace"] as? [String: Any]
    let repo = workspace?["repo"] as? [String: Any]
    if let name = repo?["name"] as? String, !name.isEmpty {
        reduced["project"] = name
    } else if let directory = (workspace?["project_dir"] as? String)
        ?? (workspace?["current_dir"] as? String)
        ?? (root["cwd"] as? String), !directory.isEmpty {
        reduced["project"] = (directory as NSString).lastPathComponent
    }

    guard reduced["session_id"] != nil else { return nil }
    return try? JSONSerialization.data(withJSONObject: reduced)
}

/// Runs the displaced status-line command with the same input, passing its
/// output through untouched.
func runWrapped(_ command: String, stdin input: Data) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.standardError

    let pipe = Pipe()
    process.standardInput = pipe

    do {
        try process.run()
    } catch {
        return 0
    }

    // Written off the main path: a payload larger than the pipe buffer would
    // otherwise wait for a reader that has not started yet.
    let handle = pipe.fileHandleForWriting
    DispatchQueue.global().async {
        try? handle.write(contentsOf: input)
        try? handle.close()
    }

    process.waitUntilExit()
    return process.terminationStatus
}

func resolveSocketURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["AGENTPET_SOCKET"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    return BridgeSocketLocation.defaultURL
}

/// Where undelivered events wait. Overridable so a test can spool somewhere
/// harmless instead of the user's Application Support directory.
func resolveSpoolURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["AGENTPET_SPOOL"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    return EventSpool.defaultDirectory
}

/// Connects, writes one frame, and closes. Never throws to the caller.
///
/// Returns whether the frame was handed to a listening runtime; a `false`
/// means the caller should spool it. Every failure path here is a failure to
/// deliver, not an error to report.
func deliver(_ envelope: BridgeEnvelope, to url: URL) -> Bool {
    guard let frame = try? envelope.encoded() else { return false }
    guard frame.count <= BridgeEnvelope.maximumPayloadBytes * 2 else { return false }
    guard url.path.utf8.count <= BridgeSocketLocation.maximumPathBytes else { return false }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    // A non-blocking connect with a hard deadline. If the runtime is wedged,
    // this returns immediately rather than inheriting its latency.
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(url.path.utf8CString)
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        pathBytes.withUnsafeBytes { source in
            destination.copyBytes(from: source)
        }
    }

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    if result != 0 && errno != EINPROGRESS { return false }
    if result != 0 && !waitWritable(fd, milliseconds: 50) { return false }

    var frameWithNewline = frame
    frameWithNewline.append(0x0A)
    return writeAll(fd, frameWithNewline)
}

/// True once the socket is writable, false on timeout or error.
func waitWritable(_ fd: Int32, milliseconds: Int32) -> Bool {
    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let ready = poll(&descriptor, 1, milliseconds)
    return ready > 0 && (descriptor.revents & Int16(POLLOUT)) != 0
}

/// Writes the whole buffer, tolerating short writes. Gives up after the poll
/// deadline rather than spinning against a peer that is not reading — and
/// says so, because an unfinished frame is one the server will discard.
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    let total = data.count

    while offset < total {
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(fd, base.advanced(by: offset), total - offset)
        }
        if written <= 0 {
            if errno == EAGAIN || errno == EINTR {
                if !waitWritable(fd, milliseconds: 50) { return false }
                continue
            }
            return false
        }
        offset += written
    }
    return true
}
