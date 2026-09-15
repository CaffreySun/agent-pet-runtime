import Foundation

/// Installs the Pi integration: one small TypeScript extension the runtime
/// owns, dropped into Pi's auto-discovered extensions directory.
///
/// Pi extensions run with the user's full permissions, so the file is written
/// plainly — readable, marked at the top, and self-contained (node built-ins
/// only, no package install, no settings edit). Uninstall deletes exactly that
/// file, and only while it still carries the marker; anything the user wrote
/// is refused rather than overwritten.
public struct PiConfigurator: AgentConfigurator {

    public let agentID = "pi"

    /// Recognises the runtime's own file. The version suffix lets a future
    /// install replace the previous copy by content rather than by trust.
    public static let marker = "// agentpet-extension v1"

    public let extensionURL: URL

    private let transaction: ConfigTransaction
    private let backupDirectory: URL

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        transaction: ConfigTransaction
    ) {
        self.extensionURL = home.appendingPathComponent(".pi/agent/extensions/agentpet.ts")
        self.transaction = transaction
        self.backupDirectory = transaction.backupDirectory
    }

    public func configurationTargets() -> [URL] { [extensionURL] }

    // MARK: - Template

    /// The path as it appears inside the template's JavaScript string literal.
    static func jsStringLiteral(_ path: String) -> String {
        path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func template(shimPath: String) -> String {
        templateSource.replacingOccurrences(
            of: "__AGENTPET_SHIM__", with: jsStringLiteral(shimPath)
        )
    }

    /// Plain JavaScript (valid TypeScript), node built-ins only. Fire and
    /// forget, the same contract the hooks keep: the pet missing an event is
    /// invisible, an extension that stalls the agent is not.
    static let templateSource = #"""
    // agentpet-extension v1 — installed by Agent Pet Runtime.
    // Reports session lifecycle and context usage to the pet, nothing else.
    // Delete this file to remove the integration; the runtime deletes it too.
    import { spawn } from "node:child_process";
    import { basename } from "node:path";

    const SHIM = "__AGENTPET_SHIM__";

    function sessionIdFor(ctx) {
      try {
        const file = ctx && ctx.sessionManager && ctx.sessionManager.getSessionFile
          ? ctx.sessionManager.getSessionFile()
          : null;
        if (file) return basename(String(file)).replace(/\.jsonl$/, "");
      } catch {}
      return `pid-${process.pid}`;
    }

    // The payload goes through the environment, not stdin. This code runs
    // inside the agent's own runtime, where a write to a pipe is queued on an
    // event loop the agent may be holding: measured on the sibling extension
    // (Oh My Pi, PR #1), a 30 ms busy stretch between spawning the shim and
    // writing to it is enough for the shim's stdin deadline to expire, and the
    // event then arrives with no session at all. The environment is handed to
    // the child by the kernel at spawn time, so there is nothing to be late for.
    function report(event, payload) {
      try {
        const env = { ...process.env };
        env.AGENTPET_PAYLOAD_BASE64 = Buffer.from(JSON.stringify(payload), "utf8").toString("base64");
        const proc = spawn(SHIM, ["--agent", "pi", "--event", event], {
          stdio: ["ignore", "ignore", "ignore"],
          detached: true,
          env,
        });
        proc.on("error", () => {});
        proc.unref();
      } catch {}
    }

    // The same reduced shape the status-line taps deliver: session id,
    // percentage, window, tokens, model. Nothing else leaves this process.
    function contextPayload(ctx) {
      try {
        const usage = ctx.getContextUsage ? ctx.getContextUsage() : null;
        const tokens = usage && usage.tokens;
        if (typeof tokens !== "number") return null;
        const model = ctx.model;
        const window = model && model.contextWindow;
        const payload = {
          session_id: sessionIdFor(ctx),
          tokens: Math.round(tokens),
          model: model ? (model.name || model.id) : undefined,
        };
        if (typeof window === "number" && window > 0) {
          payload.window = window;
          payload.used_percentage = Math.round((tokens / window) * 1000) / 10;
        }
        return payload;
      } catch {
        return null;
      }
    }

    export default function (pi) {
      pi.on("session_start", (_e, ctx) =>
        report("session_start", { session_id: sessionIdFor(ctx), cwd: ctx.cwd }));
      pi.on("agent_start", (_e, ctx) =>
        report("agent_start", { session_id: sessionIdFor(ctx), cwd: ctx.cwd }));
      pi.on("tool_execution_start", (e, ctx) =>
        report("tool_execution_start", { session_id: sessionIdFor(ctx), cwd: ctx.cwd, toolName: e.toolName }));
      pi.on("ui_prompt_start", (_e, ctx) =>
        report("ui_prompt_start", { session_id: sessionIdFor(ctx), cwd: ctx.cwd }));
      pi.on("agent_settled", (_e, ctx) => {
        report("agent_settled", { session_id: sessionIdFor(ctx), cwd: ctx.cwd });
        const context = contextPayload(ctx);
        if (context) report("context_update", context);
      });
      pi.on("session_shutdown", (_e, ctx) =>
        report("session_shutdown", { session_id: sessionIdFor(ctx), cwd: ctx.cwd }));
    }
    """#

    // MARK: - Reading

    public func entriesPresent(in record: IntegrationRecord) -> Bool {
        guard let shimPath = record.shimPath,
              let data = try? Data(contentsOf: extensionURL),
              let text = String(data: data, encoding: .utf8)
        else { return false }
        return text.contains(Self.marker)
            && text.contains(Self.jsStringLiteral(shimPath))
    }

    // MARK: - Configure

    public func configure(
        shimPath: String,
        replacing previous: IntegrationRecord?,
        now: Date
    ) throws -> ConfigurationOutcome {

        // A file that is not ours is refused, never overwritten — an
        // extension is code, and code that runs with the user's permissions
        // is not something to replace on a guess.
        if let data = try? Data(contentsOf: extensionURL),
           let existing = String(data: data, encoding: .utf8),
           !existing.contains(Self.marker) {
            throw ConfigurationError.transactionFailed(
                "\(extensionURL.path) exists and is not the runtime's file; "
                    + "move it aside first if you want the runtime to install its own."
            )
        }

        let template = Self.template(shimPath: shimPath)
        let outcome = try transaction.performText(
            on: extensionURL,
            transform: { text in text = template },
            verify: { $0.contains(Self.marker) && $0.contains(Self.jsStringLiteral(shimPath)) }
        )

        let record = IntegrationRecord(
            agentID: agentID,
            status: .configured,
            configuredAt: previous?.configuredAt ?? now,
            lastValidatedAt: now,
            shimPath: shimPath,
            entries: [WrittenEntry(file: extensionURL.path, event: "extension", command: Self.marker)]
        )

        return ConfigurationOutcome(
            record: record,
            changedFiles: outcome.didChange ? [extensionURL.path] : [],
            backupURLs: outcome.backupURL.map { [$0.path] } ?? []
        )
    }

    // MARK: - Uninstall

    public func uninstall(
        _ record: IntegrationRecord,
        now: Date
    ) throws -> ConfigurationOutcome {
        var changed = false
        var backups: [String] = []

        if let data = try? Data(contentsOf: extensionURL),
           let text = String(data: data, encoding: .utf8),
           text.contains(Self.marker) {
            // Backed up before the delete, the same as every other edit here.
            try FileManager.default.createDirectory(
                at: backupDirectory, withIntermediateDirectories: true
            )
            let backup = backupDirectory.appendingPathComponent(
                "\(extensionURL.lastPathComponent)."
                    + "\(Int(Date().timeIntervalSince1970)).\(Hashing.sha256(data).prefix(8))"
            )
            try data.write(to: backup, options: .atomic)
            backups.append(backup.path)
            try FileManager.default.removeItem(at: extensionURL)
            changed = true
        }

        let updated = IntegrationRecord(
            agentID: agentID,
            status: .notConfigured,
            configuredAt: record.configuredAt,
            lastValidatedAt: now,
            shimPath: record.shimPath,
            entries: []
        )
        return ConfigurationOutcome(
            record: updated,
            changedFiles: changed ? [extensionURL.path] : [],
            backupURLs: backups
        )
    }
}
