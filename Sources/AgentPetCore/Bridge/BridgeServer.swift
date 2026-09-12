import Darwin
import Foundation

/// Receives envelopes from `agentpet-hook` over a Unix domain socket.
///
/// Deliberately one-way and answer-free. The shim is on the agent's critical
/// path and never waits for a reply, so there is no response to send and no
/// request/response state to keep.
public final class BridgeServer: @unchecked Sendable {

    public typealias Handler = @Sendable (BridgeEnvelope) -> Void
    public typealias Diagnostic = @Sendable (String) -> Void

    private let socketURL: URL
    private let handler: Handler
    private let diagnostic: Diagnostic

    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private var isRunning = false

    /// Counts frames that arrived but could not be understood. Reported by
    /// diagnostics rather than thrown, because a malformed frame from one
    /// agent must not take the bridge down for the others.
    private var _malformedFrameCount = 0
    public var malformedFrameCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return _malformedFrameCount
    }

    public init(
        socketURL: URL = BridgeSocketLocation.defaultURL,
        handler: @escaping Handler,
        diagnostic: @escaping Diagnostic = { _ in }
    ) {
        self.socketURL = socketURL
        self.handler = handler
        self.diagnostic = diagnostic
    }

    // MARK: - Lifecycle

    public func start() throws {
        try BridgeSocketLocation.validate(socketURL)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeSocketError.cannotCreateSocket(errno: errno) }

        // Without this, writing to a peer that has gone away raises SIGPIPE and
        // kills the whole app.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // A socket left behind by a crashed run would make bind fail.
        unlink(socketURL.path)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketURL.path.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw BridgeSocketError.cannotBind(path: socketURL.path, errno: code)
        }

        // Only this user may inject events. Another account on the machine
        // being able to fake agent activity would make the pet a liar.
        chmod(socketURL.path, 0o600)

        guard listen(fd, 32) == 0 else {
            let code = errno
            close(fd)
            unlink(socketURL.path)
            throw BridgeSocketError.cannotListen(errno: code)
        }

        stateLock.lock()
        listenFD = fd
        isRunning = true
        stateLock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(fd: fd) }
        thread.name = "AgentPet.BridgeServer.accept"
        thread.stackSize = 512 * 1024
        acceptThread = thread
        thread.start()
    }

    public func stop() {
        stateLock.lock()
        let fd = listenFD
        listenFD = -1
        isRunning = false
        stateLock.unlock()

        if fd >= 0 {
            close(fd)
            unlink(socketURL.path)
        }
        acceptThread = nil
    }

    // MARK: - Accept

    private func acceptLoop(fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { return }   // listening socket closed

            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            // Serve each connection on its own thread so one stalled writer
            // cannot block the others. Agent hooks are short-lived, so these
            // are cheap.
            let connection = Thread { [weak self] in self?.readLoop(client: client) }
            connection.stackSize = 256 * 1024
            connection.start()
        }
    }

    private func readLoop(client: Int32) {
        defer { close(client) }

        var decoder = BridgeFrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let count = read(client, &buffer, buffer.count)
            if count <= 0 { return }

            let frames = decoder.append(Data(buffer[0..<count]))
            for frame in frames { deliver(frame) }
        }
    }

    private func deliver(_ frame: Data) {
        do {
            handler(try BridgeEnvelope.decode(from: frame))
        } catch {
            stateLock.lock()
            _malformedFrameCount += 1
            stateLock.unlock()
            diagnostic("unreadable bridge frame: \(error)")
        }
    }
}
