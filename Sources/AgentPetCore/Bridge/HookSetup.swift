import Foundation

/// Generates the configuration an agent needs to reach the bridge.
///
/// Kept separate from the menu so the exact text can be asserted in tests and
/// inspected without launching the app.
public enum HookSetup {

    /// Claude Code hook events worth forwarding.
    ///
    /// Not every event Claude Code offers is here. `PreCompact` and
    /// `SubagentStop` are omitted from the generated block because the former
    /// changes nothing the pet shows and the latter is already covered by the
    /// `working` state it would report.
    public static let claudeCodeEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "Notification",
        "Stop",
        "SessionEnd",
    ]

    /// The `hooks` object to merge into `~/.claude/settings.json`.
    ///
    /// Each command passes explicit `--agent` and `--event` flags so the shim
    /// never has to guess, and a five second timeout so a wedged shim is
    /// abandoned rather than left holding up the agent.
    /// Assembled as a dictionary and serialised, never by concatenating
    /// strings. The command is shell-quoted, and shell quoting emits backslash
    /// escapes that are not valid inside a JSON string — so hand-built JSON
    /// breaks on any path containing an apostrophe.
    public static func claudeCodeJSON(shimPath: String) -> String {
        var hooks: [String: Any] = [:]

        for event in claudeCodeEvents {
            hooks[event] = [[
                "matcher": "*",
                "hooks": [[
                    "type": "command",
                    "command": "\(shellQuoted(shimPath)) --agent claude-code --event \(event)",
                    "timeout": 5,
                ]],
            ]]
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: ["hooks": hooks],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let json = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return json
    }

    /// A path with spaces would otherwise split into separate arguments and the
    /// hook would silently never fire.
    public static func shellQuoted(_ path: String) -> String {
        guard path.contains(where: { $0 == " " || $0 == "\"" || $0 == "'" || $0 == "\\" }) else {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
