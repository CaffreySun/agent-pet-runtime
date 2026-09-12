import AgentPetCore
import AppKit
import Foundation

/// Command-line equivalents of the manager window's actions.
///
/// Every operation the GUI offers is available here too, so the runtime can be
/// driven from a script or a terminal — and so the operations can be verified
/// without a screen.
enum CommandLineTool {

    static func run(arguments: [String]) -> Int32 {
        let root = BridgeSocketLocation.applicationSupportDirectory
        let transaction = ConfigTransaction(
            backupDirectory: root.appendingPathComponent("backups")
        )
        let store = IntegrationStore(directory: root.appendingPathComponent("integrations"))

        if arguments.contains("--status") {
            return printStatus(store: store, transaction: transaction)
        }

        if let index = arguments.firstIndex(of: "--configure"),
           index + 1 < arguments.count {
            return configure(agentID: arguments[index + 1], store: store, transaction: transaction)
        }

        if let index = arguments.firstIndex(of: "--unconfigure"),
           index + 1 < arguments.count {
            return unconfigure(agentID: arguments[index + 1], store: store, transaction: transaction)
        }

        return 0
    }

    // MARK: - Status

    private static func printStatus(store: IntegrationStore, transaction: ConfigTransaction) -> Int32 {
        let profiles = AgentIntegrationRegistry.all(transaction: transaction)
        let detector = AgentDetector(specifications: profiles.map(\.detection))
        let evaluator = IntegrationHealthEvaluator()
        let now = Date()

        print("Agent integrations")
        print("")
        for profile in profiles {
            let detection = detector.detect(profile.detection)
            let record = store.record(for: profile.agentID)
            let present = profile.configurator.map { $0.entriesPresent(in: record) } ?? false
            let health = evaluator.health(
                record: record, isDetected: detection.isDetected,
                lastEventAt: nil, entriesPresent: present, now: now
            )

            let marker = detection.isDetected ? "●" : "○"
            print("  \(marker) \(profile.displayName)  [\(profile.agentID)]")
            print("      health:      \(health.displayName)")
            print("      executable:  \(detection.executablePath ?? "not found")")
            if let version = detection.version {
                print("      version:     \(version)")
            }
            print("      hooks:       \(record.entries.count)")
            print("      configurable:\(profile.configurator == nil ? " no" : " yes")")
        }

        print("")
        print("Note: health reads \"Degraded\" here because this command has no live")
        print("      event stream to judge freshness against. The app shows Connected")
        print("      once events actually arrive.")
        return 0
    }

    // MARK: - Configure

    private static func configure(
        agentID: String,
        store: IntegrationStore,
        transaction: ConfigTransaction
    ) -> Int32 {
        guard let profile = AgentIntegrationRegistry.profile(for: agentID, transaction: transaction) else {
            print("Unknown agent '\(agentID)'. Known: "
                  + AgentIntegrationRegistry.all(transaction: transaction)
                    .map(\.agentID).joined(separator: ", "))
            return 1
        }
        guard let configurator = profile.configurator else {
            print("\(profile.displayName) has no configurator.")
            print("Its configuration format is not one the runtime can edit safely, so it is")
            print("detected but left alone rather than half-supported.")
            return 1
        }

        let shim = shimPath()
        let previous = store.record(for: agentID)

        do {
            let outcome = try configurator.configure(
                shimPath: shim, replacing: previous, now: Date()
            )
            try store.save(outcome.record)

            print("\(profile.displayName): \(outcome.didChange ? "configured" : "already configured")")
            print("  shim:   \(shim)")
            print("  hooks:  \(outcome.record.entries.count)")
            for file in outcome.changedFiles { print("  wrote:  \(file)") }
            for backup in outcome.backupURLs { print("  backup: \(backup)") }
            if !outcome.didChange {
                print("  (nothing to change — running this again is always safe)")
            }
            return 0
        } catch {
            print("Could not configure \(profile.displayName): \(error)")
            if case ConfigTransactionError.existingContentNotJSON(let path, _) = error {
                print("")
                print("\(path) is not valid JSON. The runtime will not overwrite a file it")
                print("cannot parse, because doing so would discard whatever is in it.")
            }
            return 1
        }
    }

    private static func unconfigure(
        agentID: String,
        store: IntegrationStore,
        transaction: ConfigTransaction
    ) -> Int32 {
        guard let profile = AgentIntegrationRegistry.profile(for: agentID, transaction: transaction),
              let configurator = profile.configurator
        else {
            print("Unknown or unconfigurable agent '\(agentID)'.")
            return 1
        }

        let record = store.record(for: agentID)
        do {
            let outcome = try configurator.uninstall(record, now: Date())
            try store.save(outcome.record)

            print("\(profile.displayName): \(outcome.didChange ? "integration removed" : "nothing to remove")")
            for file in outcome.changedFiles { print("  wrote:  \(file)") }
            print("  Only the \(record.entries.count) hook(s) the runtime wrote were removed.")
            print("  Anything you wrote yourself is untouched.")
            return 0
        } catch {
            print("Could not remove the \(profile.displayName) integration: \(error)")
            return 1
        }
    }

    // MARK: - Helpers

    static func shimPath() -> String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let sibling = executable.deletingLastPathComponent().appendingPathComponent("agentpet-hook")
        return FileManager.default.isExecutableFile(atPath: sibling.path)
            ? sibling.path
            : "/path/to/agentpet-hook"
    }
}
