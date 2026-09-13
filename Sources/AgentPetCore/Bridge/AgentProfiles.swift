import Foundation

/// The shipped agent profiles.
///
/// Confidence differs by mechanism and is not cosmetic: a hook reports what
/// actually happened, while process observation only suggests it. Sending both
/// at `.high` would let a guess masquerade as a fact in the UI.
public enum AgentProfiles {

    /// Claude Code hooks.
    ///
    /// The event set below is the complete list the installed build (2.1.268)
    /// dispatches. Payloads carry `session_id`, `cwd`, `tool_name`,
    /// `notification_type`, and `background_tasks`; hooks run synchronously
    /// with the payload on stdin.
    ///
    /// The state mapping follows what the events actually mean rather than
    /// what their names suggest:
    ///
    /// - `PermissionRequest` — and `Notification` carrying
    ///   `notification_type: permission_prompt` — is the *only* signal that the
    ///   agent is genuinely blocked. It is the one state worth holding.
    /// - `Notification` is a grab bag: it also carries `idle_prompt`,
    ///   `auth_success`, and `elicitation_dialog`. Treating all of them as
    ///   "waiting for input" is what leaves the pet permanently asking for
    ///   attention once more than one session is open.
    /// - `Stop` fires at the end of *every* turn, not at the end of a session.
    ///   It means the agent has gone quiet, which is `idle`.
    /// - `TaskCompleted` is the event that means a task actually finished.
    public static let claudeCode = AgentProfile(
        agentID: "claude-code",
        displayName: "Claude Code",
        rules: [
            // --- Blocked on the user: the only sticky attention state. ---

            NormalizationRule(
                matches: ["PermissionRequest"],
                kind: .waitingApproval,
                summaryField: "tool_name",
                toolNameField: "tool_name",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            // Older builds route the same signal through Notification.
            NormalizationRule(
                matches: ["Notification"],
                kind: .waitingApproval,
                summaryField: "message",
                toolNameField: "tool_name",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd",
                whenNotificationType: "permission_prompt"
            ),

            // --- Working. ---

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
                toolNameField: "tool_name",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["PostToolUse"],
                kind: .working,
                summaryField: "tool_name",
                toolNameField: "tool_name",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            // A subagent starting or finishing does not end the session: the
            // main agent carries on, so both mean still-working.
            NormalizationRule(
                matches: ["SubagentStart", "SubagentStop"],
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
                matches: ["PostCompact"],
                kind: .working,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Finished. ---

            // A whole task finished: the one worth celebrating.
            NormalizationRule(
                matches: ["TaskCompleted"],
                kind: .completed,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            // The turn ended. This fires constantly, so it settles to idle —
            // unless a background subagent is still running, in which case the
            // agent has only paused and is still working.
            //
            // `last_assistant_message` rides along as the second line of the
            // pet's "Ready" message, the way Codex shows a preview of what the
            // agent just said. Claude Code supplies that field on `Stop`
            // specifically so hooks do not have to read the transcript.
            NormalizationRule(
                matches: ["Stop"],
                kind: .completed,
                detailField: "last_assistant_message",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd",
                suppressedByRunningBackgroundTask: true
            ),
            NormalizationRule(
                matches: ["Stop"],
                kind: .working,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Failure. ---

            NormalizationRule(
                matches: ["StopFailure"],
                kind: .failed,
                summaryField: "error",
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Lifecycle. ---

            NormalizationRule(
                matches: ["SessionStart"],
                kind: .sessionStarted,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),
            NormalizationRule(
                matches: ["SessionEnd"],
                kind: .sessionClosed,
                sessionIDField: "session_id",
                workingDirectoryField: "cwd"
            ),

            // --- Description, not state. ---

            // Arrives only when the status-line tap is installed (see
            // StatusLineTap): Claude Code runs the status-line command with
            // its own JSON, the shim reduces it to this handful of fields, and
            // the session id is the same one the hooks use. It tells the panel
            // how full a context window is and what the session is called —
            // facts hooks never carry — and deliberately changes no state.
            NormalizationRule(
                matches: ["Statusline"],
                kind: .contextUpdate,
                sessionIDField: "session_id"
            ),

            // Deliberately absent: `Notification` carrying `idle_prompt`,
            // `auth_success`, or `elicitation_dialog`, and `TeammateIdle`.
            //
            // None of them is a state the pet should show. `idle_prompt` in
            // particular only says the agent has been quiet a while, which
            // `Stop` already reported — and mapping it to a state that never
            // expires is precisely what left the pet stuck asking for attention
            // whenever more than one session was open.
            //
            // An event with no matching rule changes nothing.
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
