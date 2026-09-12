import Foundation

/// Whether an agent is installed, and where.
public struct DetectionResult: Sendable, Equatable {
    public let agentID: String
    public let executablePath: String?
    public let version: String?
    /// Configuration files that exist for this agent.
    public let presentConfigFiles: [String]

    public var isDetected: Bool { executablePath != nil }
}

public enum AgentDetectionError: Error, Equatable, Sendable {
    case notFound(String)
}

/// Finds agents on disk.
///
/// Looks only at where an agent actually is and what it says its version is.
/// Nothing here reads credentials, model configuration, or session content.
public struct AgentDetector: Sendable {

    public struct Specification: Sendable {
        public let agentID: String
        public let displayName: String
        /// Executable names to look for, in priority order.
        public let executableNames: [String]
        /// Directories to search before falling back to `PATH`.
        public let extraSearchPaths: [URL]
        /// Arguments that print a version and exit.
        public let versionArguments: [String]
        /// Configuration files that may exist for this agent.
        public let configFiles: [URL]

        public init(
            agentID: String,
            displayName: String,
            executableNames: [String],
            extraSearchPaths: [URL] = [],
            versionArguments: [String] = ["--version"],
            configFiles: [URL] = []
        ) {
            self.agentID = agentID
            self.displayName = displayName
            self.executableNames = executableNames
            self.extraSearchPaths = extraSearchPaths
            self.versionArguments = versionArguments
            self.configFiles = configFiles
        }
    }

    public var searchPaths: [URL]
    public var specifications: [Specification]
    /// Reading a version costs a process launch, so it is skipped when the
    /// caller only needs to know whether the agent exists.
    public var readVersions: Bool

    public init(
        specifications: [Specification],
        searchPaths: [URL]? = nil,
        readVersions: Bool = true
    ) {
        self.specifications = specifications
        self.searchPaths = searchPaths ?? Self.defaultSearchPaths()
        self.readVersions = readVersions
    }

    public static func defaultSearchPaths() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths: [URL] = [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/usr/bin"),
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent("bin"),
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            paths.append(contentsOf: path.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
        }
        return paths
    }

    public func detect(_ specification: Specification) -> DetectionResult {
        let executable = findExecutable(specification.executableNames)

        let configs = specification.configFiles
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(\.path)

        return DetectionResult(
            agentID: specification.agentID,
            executablePath: executable?.path,
            version: (readVersions && executable != nil) ? version(of: executable!) : nil,
            presentConfigFiles: configs
        )
    }

    public func detectAll() -> [DetectionResult] {
        specifications.map(detect)
    }

    /// First match wins, so `extraSearchPaths` can shadow a stale install.
    func findExecutable(_ names: [String]) -> URL? {
        for directory in searchPaths {
            for name in names {
                let candidate = directory.appendingPathComponent(name)
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Runs `<executable> --version` with a short timeout. An agent that hangs
    /// on `--version` must not hang the whole detection sweep.
    func version(of executable: URL) -> String? {
        guard let spec = specifications.first(where: {
            $0.executableNames.contains(executable.lastPathComponent)
        }) else { return nil }

        let process = Process()
        process.executableURL = executable
        process.arguments = spec.versionArguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Give up rather than block the caller forever.
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text.split(separator: "\n").first.map(String.init)
    }
}
