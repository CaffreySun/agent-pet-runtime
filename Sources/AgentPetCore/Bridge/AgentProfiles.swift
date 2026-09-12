import Foundation

/// The shipped agent profiles.
///
/// Confidence differs by mechanism and is not cosmetic: a hook reports what
/// actually happened, while process observation only suggests it. Sending both
/// at `.high` would let a guess masquerade as a fact in the UI.
public enum AgentProfiles {

    /// Claude Code hooks. Payloads carry `session_id`, `cwd`, and `tool_name`;
    /// hooks are invoked synchronously with the payload on stdin.
    public static let claudeCode = AgentProfile(
        agentID: "claude-code",
        displayName: "Claude Code",
        rules: [
            NormalizationRule(
                matches: ["SessionStart"],
                kind: .sessionStarted,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["UserPromptSubmit"],
                kind: .working,
                summaryField: "prompt",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["PreToolUse"],
                kind: .working,
                summaryField: "tool_name",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["PostToolUse"],
                kind: .working,
                summaryField: "tool_name",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            // Notification fires when Claude Code wants the user's attention,
            // which is exactly the `waitingInput` condition.
            NormalizationRule(
                matches: ["Notification"],
                kind: .waitingInput,
                summaryField: "message",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["Stop"],
                kind: .completed,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            // A subagent finishing does not mean the session finished, so this
            // deliberately maps to `working` rather than `completed`.
            NormalizationRule(
                matches: ["SubagentStop"],
                kind: .working,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["PreCompact"],
                kind: .working,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["SessionEnd"],
                kind: .sessionClosed,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
        ]
    )

    /// Grok documents its hook schema as matching Claude Code's, and its
    /// config uses the same `PreToolUse`-style event tables, so the mapping is
    /// shared. Kept as its own profile because the two will drift.
    public static let grok = AgentProfile(
        agentID: "grok",
        displayName: "Grok",
        rules: claudeCode.rules,
        fallbackSessionID: "grok-default"
    )

    /// Codex's `notify` hook passes a fixed argv rather than a JSON payload, so
    /// sessions cannot be distinguished and confidence is limited to what the
    /// process boundary proves.
    public static let codex = AgentProfile(
        agentID: "codex",
        displayName: "Codex",
        rules: [
            NormalizationRule(matches: ["turn-ended", "notify"], kind: .completed),
            NormalizationRule(matches: ["session-start"], kind: .sessionStarted),
            NormalizationRule(matches: ["working", "turn-started"], kind: .working),
            NormalizationRule(matches: ["session-end"], kind: .sessionClosed),
        ],
        fallbackSessionID: "codex-default",
        confidence: .medium
    )

    /// Pi reports through an in-process extension that emits the same payload
    /// shape as the normalized events themselves.
    public static let pi = AgentProfile(
        agentID: "pi",
        displayName: "Pi",
        rules: [
            NormalizationRule(
                matches: ["session_start"],
                kind: .sessionStarted,
                sessionIDField: "sessionId",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["agent_start", "turn_start", "tool_execution_start"],
                kind: .working,
                summaryField: "toolName",
                sessionIDField: "sessionId",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["ui_prompt_start"],
                kind: .waitingInput,
                sessionIDField: "sessionId",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["agent_end", "turn_end"],
                kind: .completed,
                sessionIDField: "sessionId",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["session_shutdown"],
                kind: .sessionClosed,
                sessionIDField: "sessionId",
                workingDirectoryField: "cwd"
            ),
        ]
    )

    /// Fallback for anything reached by process observation alone.
    public static let genericCLI = AgentProfile(
        agentID: "generic-cli",
        displayName: "Generic CLI",
        rules: [
            NormalizationRule(matches: ["process-started"], kind: .sessionStarted),
            NormalizationRule(matches: ["process-active"], kind: .working),
            NormalizationRule(matches: ["process-idle"], kind: .waitingInput),
            NormalizationRule(matches: ["process-exited"], kind: .sessionClosed),
        ],
        fallbackSessionID: "generic-default",
        confidence: .low
    )

    public static let all: [AgentProfile] = [claudeCode, grok, codex, pi, genericCLI]

    public static func profile(for agentID: String) -> AgentProfile? {
        all.first { $0.agentID == agentID }
    }
}
