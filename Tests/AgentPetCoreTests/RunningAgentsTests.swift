import Foundation
import Testing
@testable import AgentPetCore

@Suite("Running agents — what counts as a session")
struct RunningAgentsTests {

    /// Every command line here was copied from this machine's process table
    /// while the agents were running — the shapes a matcher has to tell apart.
    private func process(
        _ arguments: [String],
        terminal: String? = "ttys064",
        cwd: String = "/Users/someone/github"
    ) -> ObservedProcess {
        ObservedProcess(
            processID: 52960,
            parentID: 51325,
            arguments: arguments,
            terminal: terminal,
            workingDirectory: URL(fileURLWithPath: cwd)
        )
    }

    private let claudeCode = ["claude"]

    @Test("a bare `claude` in a terminal is somebody's session")
    func aSessionLooksLikeASession() {
        #expect(RunningAgents.isSession(process(["claude"]), ofAgentID: "claude-code",
                                        executableNames: claudeCode))
        // Absolute paths and a full command line are both normal.
        #expect(RunningAgents.isSession(
            process(["/Users/someone/.local/bin/claude", "--model", "opus"]),
            ofAgentID: "claude-code", executableNames: claudeCode
        ))
    }

    @Test("the agent's own machinery is not")
    func helpersAreNotSessions() {
        // `claude daemon run` — the daemon every session talks to.
        #expect(!RunningAgents.isSession(process(["claude", "daemon", "run"]),
                                         ofAgentID: "claude-code", executableNames: claudeCode))
        // `claude --bg-pty-host /tmp/…` — spawned per session for background
        // tasks, and a child of the daemon rather than of a terminal.
        #expect(!RunningAgents.isSession(
            process(["claude", "--bg-pty-host", "/tmp/xyz"], terminal: nil),
            ofAgentID: "claude-code", executableNames: claudeCode
        ))
        #expect(!RunningAgents.isSession(process(["claude", "--version"]),
                                         ofAgentID: "claude-code", executableNames: claudeCode))
    }

    @Test("no terminal, no session")
    func aProcessWithoutATerminalIsSkipped() {
        // The cheapest and most reliable discriminator there is: a session
        // somebody is watching has a tty, and everything the agent runs for
        // itself does not. A session that genuinely has none reports itself
        // through its hooks, which is what the scan is an improvement on.
        #expect(!RunningAgents.isSession(process(["claude"], terminal: nil),
                                         ofAgentID: "claude-code", executableNames: claudeCode))
    }

    @Test("another program is another program")
    func otherProgramsAreNotSessions() {
        #expect(!RunningAgents.isSession(process(["vim", "notes.md"]),
                                         ofAgentID: "claude-code", executableNames: claudeCode))
        #expect(!RunningAgents.isSession(process([]),
                                         ofAgentID: "claude-code", executableNames: claudeCode))
    }

    @Test("the environment is not an argument")
    func environmentIsNeverMistakenForArguments() {
        // The kernel hands back argv and the environment in one buffer, so a
        // reader that does not stop at argc sees `TERM_SESSION_ID=…` and the
        // like. This is the shape the earlier probe actually printed.
        let real = ObservedProcess(
            processID: 1, parentID: 1,
            arguments: ["claude"],
            terminal: "ttys064",
            workingDirectory: nil
        )
        #expect(RunningAgents.isSession(real, ofAgentID: "claude-code", executableNames: claudeCode))

        // And the live reader stops at argc: the arguments of this very process
        // are the ones it was started with, not the environment around them.
        let mine = RunningAgents.processes().first { $0.processID == getpid() }
        #expect(mine != nil)
        #expect(mine?.arguments.allSatisfy { !$0.hasPrefix("PATH=") } == true)
    }

    @Test("each agent is matched by its own name")
    func agentsAreMatchedSeparately() {
        let codex = process(["codex", "chat"])
        #expect(RunningAgents.isSession(codex, ofAgentID: "codex", executableNames: ["codex"]))
        #expect(!RunningAgents.isSession(codex, ofAgentID: "claude-code", executableNames: claudeCode))
    }
}
