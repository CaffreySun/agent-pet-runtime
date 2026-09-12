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
//   2. Never block. If the runtime is not running, the event is dropped. That
//      is the correct trade: a missed animation is invisible, a stalled agent
//      is not.
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

guard let agentID = value(of: "--agent"), !agentID.isEmpty else {
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
deliver(envelope, to: socketURL)
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

func resolveSocketURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["AGENTPET_SOCKET"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }
    return BridgeSocketLocation.defaultURL
}

/// Connects, writes one frame, and closes. Never throws to the caller: every
/// failure path is a silent drop by design.
func deliver(_ envelope: BridgeEnvelope, to url: URL) {
    guard let frame = try? envelope.encoded() else { return }
    guard frame.count <= BridgeEnvelope.maximumPayloadBytes * 2 else { return }
    guard url.path.utf8.count <= BridgeSocketLocation.maximumPathBytes else { return }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return }
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

    if result != 0 && errno != EINPROGRESS { return }
    if result != 0 && !waitWritable(fd, milliseconds: 50) { return }

    var frameWithNewline = frame
    frameWithNewline.append(0x0A)
    writeAll(fd, frameWithNewline)
}

/// True once the socket is writable, false on timeout or error.
func waitWritable(_ fd: Int32, milliseconds: Int32) -> Bool {
    var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    let ready = poll(&descriptor, 1, milliseconds)
    return ready > 0 && (descriptor.revents & Int16(POLLOUT)) != 0
}

/// Writes the whole buffer, tolerating short writes. Gives up after the poll
/// deadline rather than spinning against a peer that is not reading.
func writeAll(_ fd: Int32, _ data: Data) {
    var offset = 0
    let total = data.count

    while offset < total {
        let written = data.withUnsafeBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return write(fd, base.advanced(by: offset), total - offset)
        }
        if written <= 0 {
            if errno == EAGAIN || errno == EINTR {
                if !waitWritable(fd, milliseconds: 50) { return }
                continue
            }
            return
        }
        offset += written
    }
}
