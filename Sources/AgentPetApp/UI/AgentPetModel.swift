import AgentPetCore
import AppKit
import Foundation

/// Everything the manager windows display and everything they can do.
///
/// All mutation goes through here so the UI never touches the store, the
/// configurator, or the engine directly — which keeps "what can this window
/// change?" answerable by reading one file.
@MainActor
final class AgentPetModel: ObservableObject {

    @Published private(set) var installedPets: [InstalledPet] = []
    @Published private(set) var availablePets: [AvailablePet] = []
    @Published private(set) var agentStatuses: [AgentStatus] = []
    @Published private(set) var activities: [AgentActivity] = []
    @Published private(set) var focusedActivityID: String?

    @Published var statusMessage: String?
    @Published var errorMessage: String?
    @Published var isBusy = false
    /// Which pet the desktop is currently showing, so the list can mark it.
    @Published var currentPetID: String?

    /// Persisted user settings.
    @Published var config: AppConfig {
        didSet { if config != oldValue { saveConfig() } }
    }

    struct AvailablePet: Identifiable {
        let id: String
        let name: String
        let root: URL
        let alreadyInstalled: Bool
    }

    let petStore: PetStore
    let integrationService: AgentIntegrationService
    let transaction: ConfigTransaction

    /// Resolved at launch and passed in; the UI never guesses it.
    let shimPath: String

    private let onActivitiesChanged: ([AgentActivity], String?) -> Void
    private let configStore: AppConfigStore
    let transitionLog: TransitionLog

    init(
        root: URL,
        shimPath: String,
        onActivitiesChanged: @escaping ([AgentActivity], String?) -> Void = { _, _ in }
    ) {
        self.shimPath = shimPath
        self.petStore = PetStore(root: root)
        self.transaction = ConfigTransaction(
            backupDirectory: root.appendingPathComponent("backups")
        )
        self.integrationService = AgentIntegrationService(
            store: IntegrationStore(directory: root.appendingPathComponent("integrations")),
            detector: AgentDetector(specifications: []),
            evaluator: IntegrationHealthEvaluator()
        )
        self.configStore = AppConfigStore(
            url: root.appendingPathComponent("config.json")
        )
        self.config = configStore.load()
        self.transitionLog = TransitionLog(
            limit: max(1, configStore.load().diagnostics.transitionHistoryLimit)
        )
        self.onActivitiesChanged = onActivitiesChanged
    }

    func saveConfig() {
        try? configStore.save(config)
    }

    // MARK: - Refresh

    func refreshAll() {
        refreshPets()
        refreshAgents()
    }

    func refreshPets() {
        installedPets = petStore.installedPets()
        availablePets = petStore.discoverCodexPets().map {
            AvailablePet(id: $0.root.lastPathComponent, name: $0.name,
                         root: $0.root, alreadyInstalled: $0.alreadyInstalled)
        }
    }

    func refreshAgents() {
        let profiles = AgentIntegrationRegistry.all(transaction: transaction)
        let detector = AgentDetector(specifications: profiles.map(\.detection))
        agentStatuses = profiles.map { profile in
            let detection = detector.detect(profile.detection)
            let record = integrationService.recordFor(agentID: profile.agentID)
            let present = profile.configurator.map { $0.entriesPresent(in: record) } ?? false
            let last = integrationService.lastEventAt[profile.agentID]
            let health = IntegrationHealthEvaluator().health(
                record: record,
                isDetected: detection.isDetected,
                lastEventAt: last,
                entriesPresent: present,
                now: Date()
            )
            return AgentStatus(
                profile: profile, detection: detection, record: record,
                health: health, lastEventAt: last
            )
        }
    }

    func updateActivities(_ activities: [AgentActivity], focusedID: String?) {
        self.activities = activities
        self.focusedActivityID = focusedID
        if config.diagnostics.loggingEnabled {
            for activity in activities { transitionLog.record(activity) }
        }
    }

    // MARK: - Diagnostics

    func exportDiagnostics(to url: URL) {
        run("Exported diagnostics") {
            let bundle = DiagnosticsBundle(
                app: DiagnosticsBundle.currentAppInfo(),
                bridge: bridgeSummary(),
                pets: petStore.installedPets().map {
                    DiagnosticsBundle.PetSummary(
                        id: $0.id,
                        displayName: $0.metadata.displayName,
                        profile: $0.metadata.compatibilityProfile,
                        compatibilityWarningCount: 0
                    )
                },
                agents: agentStatuses.map {
                    DiagnosticsBundle.AgentSummary(
                        agentID: $0.profile.agentID,
                        detected: $0.detection.isDetected,
                        executablePath: $0.detection.executablePath,
                        version: $0.detection.version,
                        integrationStatus: $0.record.status.rawValue,
                        health: $0.health.displayName,
                        hookCount: $0.record.entries.count,
                        lastEventAt: $0.lastEventAt
                    )
                },
                transitions: transitionLog.transitions
            )
            try bundle.json().write(to: url, options: .atomic)
            statusMessage = "Diagnostics written to \(url.lastPathComponent)"
        }
    }

    /// Filled in by the app once the bridge is running.
    var bridgeSummary: () -> DiagnosticsBundle.BridgeSummary = {
        DiagnosticsBundle.BridgeSummary(
            isListening: false, socketPath: "", eventsReceived: 0, malformedFrames: 0
        )
    }

    func noteEvent(agentID: String) {
        integrationService.recordEvent(agentID: agentID)
    }

    // MARK: - Pet actions

    func installPet(from url: URL) {
        run("Installed \(url.lastPathComponent)") {
            _ = try petStore.install(from: url, provenance: .imported)
            refreshPets()
        }
    }

    func importAvailable(_ pet: AvailablePet) {
        run("Imported \(pet.name)") {
            _ = try petStore.install(from: pet.root, provenance: .codexPets)
            refreshPets()
        }
    }

    func upgradePet(_ pet: InstalledPet, from url: URL) {
        run("Upgraded \(pet.metadata.displayName)") {
            _ = try petStore.upgrade(petID: pet.id, from: url)
            refreshPets()
        }
    }

    func uninstallPet(_ pet: InstalledPet) {
        run("Removed \(pet.metadata.displayName)") {
            let outcome = try petStore.uninstall(petID: pet.id)
            if !outcome.removedFromDisk, let source = outcome.sourcePreserved {
                statusMessage = "Deregistered. The original at \(source) was left untouched."
            }
            refreshPets()
        }
    }

    func usePet(_ pet: InstalledPet) {
        onUsePet?(pet)
        currentPetID = pet.id
        statusMessage = "“\(pet.metadata.displayName)” is now on the desktop."
    }

    /// Set by the app to switch the desktop pet.
    var onUsePet: ((InstalledPet) -> Void)?

    // MARK: - Agent actions

    func configureAgent(_ status: AgentStatus) {
        run("Configured \(status.displayName)") {
            let outcome = try integrationService.configure(
                agentID: status.profile.agentID,
                shimPath: shimPath,
                transaction: transaction
            )
            statusMessage = outcome.didChange
                ? "Wrote hooks to \(outcome.changedFiles.joined(separator: ", "))"
                : "Already configured — nothing to change."
            refreshAgents()
        }
    }

    func removeAgentIntegration(_ status: AgentStatus) {
        run("Removed \(status.displayName) integration") {
            let outcome = try integrationService.uninstall(
                agentID: status.profile.agentID,
                transaction: transaction
            )
            statusMessage = outcome.didChange
                ? "Removed hooks. A backup of the previous file was kept."
                : "Nothing to remove."
            refreshAgents()
        }
    }

    /// Feeds a synthetic event through the real pipeline, which is what makes
    /// it a test of the integration rather than of the animation.
    func sendTestEvent(agentID: String) {
        let event = AgentEvent(
            agentID: agentID,
            sessionID: "test-session",
            kind: .waitingInput,
            at: Date(),
            confidence: EventConfidence(level: .high, source: "test"),
            summary: "Test event from Agent Pet Runtime"
        )
        onTestEvent?(event)
        statusMessage = "Sent a test event as \(agentID). The pet should react."
    }

    var onTestEvent: ((AgentEvent) -> Void)?

    // MARK: - Activity actions

    func focus(_ activity: AgentActivity) {
        // v0.1 cannot raise another app's window: hook payloads carry no
        // terminal identity. Opening the project directory is the honest
        // fallback, and the design allows for it.
        guard let target = activity.focusTarget, let path = target.path else {
            statusMessage = "No project directory is known for this session."
            return
        }
        switch target.kind {
        case .directory, .file:
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            statusMessage = "Opened \(path)"
        case .none:
            statusMessage = "This session has no location to open."
        }
    }

    // MARK: - Plumbing

    private func run(_ successMessage: String, _ work: () throws -> Void) {
        isBusy = true
        defer { isBusy = false }
        do {
            try work()
            statusMessage = successMessage
            errorMessage = nil
        } catch {
            errorMessage = describe(error)
            statusMessage = nil
        }
    }

    /// Turns errors into something a user can act on rather than a type name.
    private func describe(_ error: Error) -> String {
        switch error {
        case let PetStoreError.validationFailed(petID, issues):
            return "“\(petID)” was rejected:\n" + issues.prefix(3).joined(separator: "\n")
        case let PetStoreError.notInstalled(petID):
            return "“\(petID)” is not installed."
        case let PetStoreError.upgradeFailedAndRestored(petID, detail):
            return "Upgrading “\(petID)” failed and the previous version was restored.\n\(detail)"
        case let PetStoreError.stagingFailed(detail):
            return "Could not install: \(detail)"
        case let ConfigTransactionError.concurrentModification(path):
            return "\(path) changed while it was being edited. Nothing was written — try again."
        case let ConfigTransactionError.existingContentNotJSON(path, _):
            return "\(path) is not valid JSON. Fix it first; the runtime will not overwrite it."
        case let ConfigTransactionError.unreadable(path, detail):
            return "Could not read \(path): \(detail)"
        case let ConfigurationError.unknownAgent(id):
            return "No configurator exists for \(id)."
        case let PetPackageError.manifestInvalid(name, detail):
            return "“\(name)” has an unusable pet.json: \(detail)"
        case let PetPackageError.manifestNotFound(name):
            return "“\(name)” has no pet.json."
        default:
            return "\(error)"
        }
    }
}
