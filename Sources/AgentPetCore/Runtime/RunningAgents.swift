import Darwin
import Foundation

/// What the process table says about one process.
///
/// The facts a scan can prove without any cooperation from the agent and
/// without special permissions: which program it is, whether a terminal is
/// attached, and where it was started.
public struct ObservedProcess: Sendable, Equatable {
    public let processID: Int32
    public let parentID: Int32
    /// Its arguments, and only its arguments — never the environment, which
    /// follows them in the kernel's buffer and would match all sorts of names.
    public let arguments: [String]
    /// The controlling terminal, e.g. `ttys004`. A session a user is looking at
    /// has one; an agent's own helpers do not.
    public let terminal: String?
    public let workingDirectory: URL?

    public init(
        processID: Int32,
        parentID: Int32,
        arguments: [String],
        terminal: String?,
        workingDirectory: URL?
    ) {
        self.processID = processID
        self.parentID = parentID
        self.arguments = arguments
        self.terminal = terminal
        self.workingDirectory = workingDirectory
    }
}

/// A session that exists right now and has not said anything yet.
public struct RunningAgent: Sendable, Equatable {
    public let agentID: String
    public let processID: Int32
    public let terminal: String?
    public let workingDirectory: URL?

    public init(agentID: String, processID: Int32, terminal: String?, workingDirectory: URL?) {
        self.agentID = agentID
        self.processID = processID
        self.terminal = terminal
        self.workingDirectory = workingDirectory
    }
}

/// Finds the agents that are running right now.
///
/// Hooks fire around work, so a session sitting at its prompt says nothing at
/// all — and naming the gap only when a hook finally arrives means a pet
/// launched into that silence shows nothing while three sessions are open
/// beside it. `SPEC-REVIEW.md` called for exactly this: look at what is
/// running when the app starts, so there is a starting picture.
///
/// What a scan proves is that a session exists; what it cannot prove is what
/// that session is *doing*. So its findings arrive as placeholders at the
/// lowest confidence, and the first real event from that process replaces one.
public enum RunningAgents {

    /// Arguments that mean "this process is the agent's own machinery, not
    /// somebody's session": a daemon, an updater, the background PTY host that
    /// Claude Code spawns for its own tasks, a version probe.
    ///
    /// A denylist rather than an allowlist because the cost of the two mistakes
    /// is not symmetric: a helper shown as a session is a row that never goes
    /// away, while a session wrongly skipped still reports itself on its next
    /// hook — which is the behaviour this exists to improve on.
    static let nonSessionArguments: Set<String> = [
        "daemon", "update", "upgrade", "install", "uninstall", "doctor", "migrate",
        "setup", "mcp", "login", "logout", "completion", "help",
        "--version", "-v", "--help", "-h", "--bg-pty-host",
    ]

    /// Whether one process looks like a session of this agent.
    ///
    /// Three things have to hold, and each one earns its place:
    ///
    /// - the program is one of the agent's executables, by name;
    /// - a terminal is attached — the shape of a session someone is watching,
    ///   and what separates `claude` from `claude daemon run`;
    /// - no argument names the agent's own machinery.
    public static func isSession(
        _ process: ObservedProcess,
        ofAgentID agentID: String,
        executableNames: [String]
    ) -> Bool {
        guard let program = process.arguments.first else { return false }
        let name = (program as NSString).lastPathComponent.lowercased()
        guard executableNames.contains(where: { $0.lowercased() == name }) else { return false }
        guard process.terminal != nil else { return false }

        // The agent may be launched through a wrapper (`node …/pi`, a shim
        // script), so the machine names are looked for anywhere near the front
        // of the command line — but only in the arguments, never in what
        // follows them.
        return !process.arguments.dropFirst().contains { nonSessionArguments.contains($0.lowercased()) }
    }

    /// Every session running right now, for the agents given.
    public static func scan(profiles: [AgentProfile], executableNames: [String: [String]]) -> [RunningAgent] {
        processes().flatMap { process -> [RunningAgent] in
            profiles.compactMap { profile in
                let names = executableNames[profile.agentID] ?? []
                guard isSession(process, ofAgentID: profile.agentID, executableNames: names) else {
                    return nil
                }
                return RunningAgent(
                    agentID: profile.agentID,
                    processID: process.processID,
                    terminal: process.terminal,
                    workingDirectory: process.workingDirectory
                )
            }
        }
    }

    // MARK: - The live half

    /// Every process this user can see, through libproc.
    public static func processes() -> [ObservedProcess] {
        allPIDs().compactMap { pid in
            let arguments = arguments(of: pid)
            guard !arguments.isEmpty else { return nil }
            return ObservedProcess(
                processID: pid,
                parentID: parent(of: pid) ?? 0,
                arguments: arguments,
                terminal: terminal(of: pid),
                workingDirectory: workingDirectory(of: pid)
            )
        }
    }

    static func allPIDs() -> [Int32] {
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytes > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.size + 16)
        let written = proc_listpids(
            UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<Int32>.size)
        )
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written) / MemoryLayout<Int32>.size)).filter { $0 > 0 }
    }

    /// The process's arguments, and nothing after them.
    ///
    /// `KERN_PROCARGS2` hands back one buffer: `argc`, the executable path,
    /// padding, then `argv` and the environment together. Reading to the end of
    /// the buffer rather than to `argc` picks up environment variables, and an
    /// agent named in `TERM_SESSION_ID` or a plugin path would then look like a
    /// session.
    static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }

        let count = buffer.withUnsafeBytes { $0.load(fromByteOffset: 0, as: Int32.self) }
        guard count > 0, count < 4096 else { return [] }

        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        while index < size, arguments.count < Int(count) {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }

    static func parent(of pid: Int32) -> Int32? {
        bsdInfo(of: pid).map { Int32($0.pbi_ppid) }
    }

    static func terminal(of pid: Int32) -> String? {
        guard let info = bsdInfo(of: pid), let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR)
        else { return nil }
        let text = String(cString: name)
        return text.isEmpty || text == "??" ? nil : text
    }

    static func workingDirectory(of pid: Int32) -> URL? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    private static func bsdInfo(of pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(size)) == size else { return nil }
        return info
    }
}
