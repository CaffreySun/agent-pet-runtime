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
    /// Whether the accept loop is still taking connections. "Listening" has to
    /// mean somebody is there to accept: a bound socket whose loop has ended
    /// still answers `connect`, and reads nothing.
    private var _isAccepting = false
    private var openConnections = 0

    /// True while connections are being accepted. False means the bridge is
    /// deaf, whatever the socket file says.
    public var isAccepting: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isAccepting
    }

    /// Connections served at once. Each one is a thread and a descriptor, and
    /// agent hooks are short-lived, so this is far above any real concurrency —
    /// it exists so that a flood cannot take the process's descriptors with it.
    static let maximumConnections = 64

    /// How long a connection may sit silent before it is dropped. A hook sends
    /// its frame and closes; a peer that does neither is holding a thread.
    static let readTimeout: TimeInterval = 5

    /// How long a connection may go unclaimed before the bridge assumes the
    /// thread that was meant to serve it never started.
    static let threadStartGrace: TimeInterval = 1

    /// Connections whose thread has been started but has not reported in.
    ///
    /// `Thread.start()` cannot fail loudly: if the system will not create the
    /// thread, nothing runs, and the descriptor and the connection count would
    /// be held for the life of the process — one slot of the cap lost each
    /// time. The accept loop sweeps this instead, so an unclaimed connection is
    /// closed rather than kept by a thread that never existed.
    private var unclaimed: [Int32: Date] = [:]

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

    /// How long to wait for another runtime to finish leaving before giving up
    /// on the socket path. An upgrade stops the old app and starts the new one,
    /// so for a moment both exist and the old one still answers.
    static let handoverWait: TimeInterval = 1

    /// How often to look while waiting for that handover.
    static let handoverPoll: TimeInterval = 0.2

    public func start() throws {
        try BridgeSocketLocation.validate(socketURL)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // A socket that *answers* is not ours to remove. Every hook in the
        // user's agents connects to this one path, so a second runtime that
        // unlinks it leaves the first pet deaf until it restarts — the pet the
        // user is actually watching. A file left behind by a crash is the
        // opposite case: nothing answers on it, it would make bind fail, and
        // removing it is exactly what it is for.
        var waited: TimeInterval = 0
        while BridgeSocketLocation.hasListener(at: socketURL) {
            guard waited < Self.handoverWait else {
                throw BridgeSocketError.alreadyRunning(path: socketURL.path)
            }
            Thread.sleep(forTimeInterval: Self.handoverPoll)
            waited += Self.handoverPoll
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeSocketError.cannotCreateSocket(errno: errno) }

        // Without this, writing to a peer that has gone away raises SIGPIPE and
        // kills the whole app.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // Nothing answered above, so whatever is here is a leftover.
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
        _isAccepting = true
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
        _isAccepting = false
        stateLock.unlock()

        if fd >= 0 {
            close(fd)
            unlink(socketURL.path)
        }

        // Anything still unclaimed is a connection with no thread behind it.
        stateLock.lock()
        let stranded = Array(unclaimed.keys)
        unclaimed.removeAll()
        openConnections -= stranded.count
        stateLock.unlock()
        for client in stranded { close(client) }

        acceptThread = nil
    }

    // MARK: - Accept

    /// What an `accept` error means for the loop.
    ///
    /// The distinction that matters is between a listening socket that is
    /// *gone* — we closed it, or the process is going away — and one that is
    /// merely unable to take this connection right now. Treating the second as
    /// the first is how the bridge used to die for good: one descriptor
    /// exhaustion later, the menu still said "listening", every hook failed to
    /// connect, and nothing ever said so.
    enum AcceptFailure: Equatable {
        /// This connection failed; the listener is fine.
        case retryNow
        /// Too many open files. The listener is fine, the process is not.
        case outOfDescriptors
        /// The socket itself is unusable.
        case fatal
    }

    static func acceptFailure(for errno: Int32) -> AcceptFailure {
        switch errno {
        case EINTR, ECONNABORTED, EPROTO:
            return .retryNow
        case EMFILE, ENFILE:
            return .outOfDescriptors
        default:
            return .fatal
        }
    }

    /// How long to wait before trying `accept` again when the process is out
    /// of descriptors. Long enough not to spin, short enough that the bridge
    /// is back the moment a descriptor is freed.
    static let descriptorBackoff: TimeInterval = 0.1

    /// The connections in `unclaimed` that have been waiting too long — pure,
    /// so the rule can be tested without a system that refuses threads.
    static func abandoned(_ unclaimed: [Int32: Date], now: Date) -> [Int32] {
        unclaimed.filter { now.timeIntervalSince($0.value) >= threadStartGrace }.map(\.key)
    }

    /// Closes anything whose thread never claimed it.
    private func sweepUnclaimedThreads() {
        let abandoned = Self.abandoned(unclaimed, now: Date())
        guard !abandoned.isEmpty else { return }

        stateLock.lock()
        for client in abandoned {
            _ = unclaimed.removeValue(forKey: client)
            openConnections -= 1
        }
        stateLock.unlock()

        for client in abandoned { close(client) }
        diagnostic(
            "the bridge closed \(abandoned.count) connection(s) whose thread never started"
        )
    }

    private func acceptLoop(fd: Int32) {
        var reportedDescriptorTrouble = false
        var reportedConnectionLimit = false

        while true {
            // Cheap when nothing is pending, and the only moment it can matter:
            // a connection is only ever added just before its thread starts.
            sweepUnclaimedThreads()

            let client = accept(fd, nil, nil)
            if client < 0 {
                let code = errno
                switch Self.acceptFailure(for: code) {
                case .retryNow:
                    continue
                case .outOfDescriptors:
                    if !reportedDescriptorTrouble {
                        reportedDescriptorTrouble = true
                        diagnostic(
                            "the bridge is out of file descriptors (errno \(code)); "
                            + "still listening, retrying every \(Self.descriptorBackoff)s"
                        )
                    }
                    Thread.sleep(forTimeInterval: Self.descriptorBackoff)
                    continue
                case .fatal:
                    stateLock.lock()
                    let wasRunning = isRunning
                    _isAccepting = false
                    stateLock.unlock()
                    // Closing the socket in `stop()` lands here too, and that
                    // is not a fault worth reporting.
                    if wasRunning {
                        diagnostic("the bridge stopped accepting connections (errno \(code))")
                    }
                    return
                }
            }
            reportedDescriptorTrouble = false

            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // A peer that connects and then says nothing holds a descriptor and
            // a thread for as long as it likes; a hook sends its frame
            // immediately or not at all.
            var timeout = timeval(tv_sec: Int(Self.readTimeout), tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

            // Serve each connection on its own thread so one stalled writer
            // cannot block the others. Agent hooks are short-lived, so these
            // are cheap — and the count is capped, so "cheap" stays true when
            // something goes wrong at the other end.
            guard let connection = connectionThread(client: client) else {
                if !reportedConnectionLimit {
                    reportedConnectionLimit = true
                    diagnostic(
                        "the bridge is at its \(Self.maximumConnections)-connection limit; "
                        + "refusing connections until it drains"
                    )
                }
                close(client)
                continue
            }
            reportedConnectionLimit = false
            connection.start()
        }
    }

    /// A thread that will read one connection, or nil when the bridge is
    /// already serving as many as it will.
    private func connectionThread(client: Int32) -> Thread? {
        stateLock.lock()
        guard openConnections < Self.maximumConnections else {
            stateLock.unlock()
            return nil
        }
        openConnections += 1
        unclaimed[client] = Date()
        stateLock.unlock()

        let connection = Thread { [weak self] in
            defer { self?.connectionFinished(client: client) }
            self?.claim(client)
            self?.readLoop(client: client)
        }
        connection.stackSize = 256 * 1024
        return connection
    }

    /// The thread is running: this connection is no longer a possible orphan.
    private func claim(_ client: Int32) {
        stateLock.lock()
        unclaimed.removeValue(forKey: client)
        stateLock.unlock()
    }

    private func connectionFinished(client: Int32) {
        stateLock.lock()
        openConnections -= 1
        unclaimed.removeValue(forKey: client)
        stateLock.unlock()
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
