import Foundation
import Testing
@testable import AgentPetCore

/// Where the detector looks for an agent, against a faked home.
///
/// This is the search order in one place. It decides whether a user who
/// installed an agent with fnm, nvm, volta, bun, pnpm, asdf or mise sees it in
/// the manager at all: a GUI app is launched by launchd, whose `PATH` is
/// `/usr/bin:/bin:/usr/sbin:/sbin`, so nothing they installed appears in the
/// environment the app can see for itself.
@Suite("Agent detection search paths")
struct AgentDetectorTests {

    /// A scratch home, cleaned up when the test ends.
    private final class FakeHome {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("agentpet-home-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Writes an executable at a path relative to the fake home. Only the
        /// executable bit matters to detection, not the contents.
        @discardableResult
        func executable(_ relativePath: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path
            )
            return url
        }

        /// What the app computes on a machine whose environment is `environment`.
        func searchPaths(_ environment: [String: String] = [:]) -> [URL] {
            AgentDetector.defaultSearchPaths(home: root, environment: environment)
        }
    }

    private func pi(extraSearchPaths: [URL] = []) -> AgentDetector.Specification {
        .init(
            agentID: "pi",
            displayName: "Pi",
            executableNames: ["pi"],
            extraSearchPaths: extraSearchPaths
        )
    }

    // MARK: - Version managers

    @Test("an agent installed by fnm is found where a GUI launch can see it")
    func findsFNMInstall() throws {
        let home = try FakeHome()
        let pi = try home.executable(".local/share/fnm/node-versions/v24.13.0/installation/bin/pi")

        let detector = AgentDetector(
            specifications: [self.pi()],
            searchPaths: home.searchPaths(["PATH": "/usr/bin:/bin"]),
            readVersions: false
        )
        let result = detector.detect(self.pi())

        #expect(result.isDetected)
        #expect(result.executablePath == pi.path)
    }

    @Test("an agent installed by nvm is found too")
    func findsNVMInstall() throws {
        let home = try FakeHome()
        let pi = try home.executable(".nvm/versions/node/v22.19.0/bin/pi")

        let detector = AgentDetector(
            specifications: [self.pi()],
            searchPaths: home.searchPaths(["PATH": "/usr/bin:/bin"]),
            readVersions: false
        )

        #expect(detector.detect(self.pi()).executablePath == pi.path)
    }

    @Test("with several versions installed, the newest one is the one reported")
    func newestVersionWins() throws {
        let home = try FakeHome()
        try home.executable(".local/share/fnm/node-versions/v22.19.0/installation/bin/pi")
        let newest = try home.executable(".local/share/fnm/node-versions/v24.13.0/installation/bin/pi")

        let detector = AgentDetector(
            specifications: [self.pi()],
            searchPaths: home.searchPaths(["PATH": "/usr/bin:/bin"]),
            readVersions: false
        )

        #expect(detector.detect(self.pi()).executablePath == newest.path)
    }

    @Test("versions sort newest first, and a name with no version sorts last")
    func versionOrdering() {
        #expect(
            AgentDetector.newestFirst(["v22.19.0", "lts", "v24.13.0", "24"])
                == ["v24.13.0", "24", "v22.19.0", "lts"]
        )
        // Two-digit components are numbers, not text: v9 is older than v10.
        #expect(AgentDetector.newestFirst(["v9.11.2", "v10.0.0"]) == ["v10.0.0", "v9.11.2"])
    }

    // MARK: - Order

    @Test("the directories a terminal launch relied on still come first")
    func fixedDirectoriesComeFirst() throws {
        let home = try FakeHome()
        let paths = home.searchPaths(["PATH": "/usr/bin:/bin"]).map(\.path)

        #expect(Array(paths.prefix(5)) == [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            home.root.appendingPathComponent(".local/bin").path,
            home.root.appendingPathComponent("bin").path,
        ])
    }

    @Test("a PATH entry outranks a version-manager directory")
    func processPathOutranksVersionManagers() throws {
        let home = try FakeHome()
        try home.executable(".local/share/fnm/node-versions/v24.13.0/installation/bin/pi")

        let paths = home.searchPaths(["PATH": "/custom/bin"]).map(\.path)
        let fromPath = try #require(paths.firstIndex(of: "/custom/bin"))
        let fromFnM = try #require(
            paths.firstIndex { $0.hasSuffix("node-versions/v24.13.0/installation/bin") }
        )

        #expect(fromPath < fromFnM)
    }

    @Test("a profile's own extra search paths are searched before everything else")
    func extraSearchPathsAreSearched() throws {
        let home = try FakeHome()
        let elsewhere = try home.executable("opt/agent/bin/pi")

        let specification = pi(
            extraSearchPaths: [home.root.appendingPathComponent("opt/agent/bin")]
        )
        let detector = AgentDetector(
            specifications: [specification],
            searchPaths: home.searchPaths(["PATH": "/usr/bin:/bin"]),
            readVersions: false
        )

        #expect(detector.detect(specification).executablePath == elsewhere.path)
    }

    // MARK: - Version probe

    @Test("the version probe runs with the searched directories on PATH")
    func probeEnvironmentCarriesSearchPaths() throws {
        let home = try FakeHome()
        try home.executable(".local/share/fnm/node-versions/v24.13.0/installation/bin/node")
        let detector = AgentDetector(
            specifications: [],
            searchPaths: home.searchPaths(["PATH": "/usr/bin:/bin"]),
            readVersions: false
        )

        let path = try #require(detector.probeEnvironment()["PATH"])

        // A version manager installs a script, not a binary: `pi` starts
        // `#!/usr/bin/env node`, so `node` has to be reachable or the probe
        // exits 127 and the agent reports no version.
        #expect(path.contains(home.root.appendingPathComponent(".local/bin").path))
        #expect(path.contains(home.root.appendingPathComponent(".local/share/fnm").path))
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        #expect(path.hasSuffix(inherited))
    }
}
