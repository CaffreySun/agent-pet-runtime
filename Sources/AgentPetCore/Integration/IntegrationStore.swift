import Foundation

/// Persists one `IntegrationRecord` per agent.
///
/// Holds no secrets and no derived state. Whether an agent is installed, and
/// whether events are arriving, are recomputed on every read — a cached
/// `connected` flag would be wrong the moment an agent quits.
public final class IntegrationStore: @unchecked Sendable {

    public let directory: URL
    private let fileManager: FileManager

    public init(
        directory: URL = BridgeSocketLocation.applicationSupportDirectory
            .appendingPathComponent("integrations"),
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    public func url(for agentID: String) -> URL {
        directory.appendingPathComponent("\(agentID).json")
    }

    /// Encoder and decoder must agree on the date strategy, or records written
    /// successfully will fail to read back and silently look empty. They are
    /// built in one place so the two cannot drift apart.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public func record(for agentID: String) -> IntegrationRecord {
        guard let data = try? Data(contentsOf: url(for: agentID)),
              let record = try? Self.makeDecoder().decode(IntegrationRecord.self, from: data)
        else {
            return IntegrationRecord(agentID: agentID)
        }
        return record
    }

    public func allRecords() -> [IntegrationRecord] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { try? Self.makeDecoder().decode(
                IntegrationRecord.self, from: Data(contentsOf: $0)
            ) }
    }

    public func save(_ record: IntegrationRecord) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.makeEncoder().encode(record).write(to: url(for: record.agentID), options: .atomic)
    }

    public func remove(agentID: String) {
        try? fileManager.removeItem(at: url(for: agentID))
    }
}

/// Everything the UI needs to show one agent, assembled from what is true now.
public struct AgentStatus: Sendable, Identifiable {
    public let profile: AgentIntegrationProfile
    public let detection: DetectionResult
    public let record: IntegrationRecord
    public let health: IntegrationHealth
    public let lastEventAt: Date?

    public init(
        profile: AgentIntegrationProfile,
        detection: DetectionResult,
        record: IntegrationRecord,
        health: IntegrationHealth,
        lastEventAt: Date?
    ) {
        self.profile = profile
        self.detection = detection
        self.record = record
        self.health = health
        self.lastEventAt = lastEventAt
    }

    public var id: String { profile.agentID }
    public var displayName: String { profile.displayName }
    public var canConfigure: Bool { profile.configurator != nil }
    public var canUninstall: Bool { record.isConfigured && profile.configurator != nil }
}

/// Ties detection, configuration, and stored records together.
public final class AgentIntegrationService: @unchecked Sendable {

    private let store: IntegrationStore
    private let detector: AgentDetector
    private let evaluator: IntegrationHealthEvaluator

    /// Set by the app whenever an event arrives, so health can reflect reality.
    public var lastEventAt: [String: Date] = [:]

    public init(
        store: IntegrationStore,
        detector: AgentDetector,
        evaluator: IntegrationHealthEvaluator = IntegrationHealthEvaluator()
    ) {
        self.store = store
        self.detector = detector
        self.evaluator = evaluator
    }

    public func statuses(transaction: ConfigTransaction, now: Date = Date()) -> [AgentStatus] {
        AgentIntegrationRegistry.all(transaction: transaction).map { profile in
            status(for: profile, now: now)
        }
    }

    public func status(for profile: AgentIntegrationProfile, now: Date = Date()) -> AgentStatus {
        let detection = detector.detect(profile.detection)
        let record = store.record(for: profile.agentID)
        let lastEvent = lastEventAt[profile.agentID]

        // Only meaningful when we can actually check the file.
        var present = true
        if let configurator = profile.configurator, record.isConfigured {
            present = configurator.entriesPresent(in: record)
        }

        let health = evaluator.health(
            record: record,
            isDetected: detection.isDetected,
            lastEventAt: lastEvent,
            entriesPresent: present,
            now: now
        )

        return AgentStatus(
            profile: profile,
            detection: detection,
            record: record,
            health: health,
            lastEventAt: lastEvent
        )
    }

    @discardableResult
    public func configure(
        agentID: String,
        shimPath: String,
        transaction: ConfigTransaction,
        now: Date = Date()
    ) throws -> ConfigurationOutcome {
        guard let profile = AgentIntegrationRegistry.profile(for: agentID, transaction: transaction),
              let configurator = profile.configurator
        else {
            throw ConfigurationError.unknownAgent(agentID)
        }

        let previous = store.record(for: agentID)
        do {
            let outcome = try configurator.configure(
                shimPath: shimPath, replacing: previous, now: now
            )
            try store.save(outcome.record)
            return outcome
        } catch {
            // Record the failure so the UI can show it, but keep whatever
            // entries we knew about: the transaction has already restored the
            // file, and forgetting them would make a later removal impossible.
            var failed = previous
            failed.status = .configureFailed
            try? store.save(failed)
            throw error
        }
    }

    @discardableResult
    public func uninstall(
        agentID: String,
        transaction: ConfigTransaction,
        now: Date = Date()
    ) throws -> ConfigurationOutcome {
        guard let profile = AgentIntegrationRegistry.profile(for: agentID, transaction: transaction),
              let configurator = profile.configurator
        else {
            throw ConfigurationError.unknownAgent(agentID)
        }

        let record = store.record(for: agentID)
        let outcome = try configurator.uninstall(record, now: now)
        try store.save(outcome.record)
        return outcome
    }

    public func recordEvent(agentID: String, at date: Date = Date()) {
        lastEventAt[agentID] = date
    }

    /// Direct access for callers that have already run detection and do not
    /// want to spawn a `--version` process per agent on every refresh.
    public func recordFor(agentID: String) -> IntegrationRecord {
        store.record(for: agentID)
    }
}
