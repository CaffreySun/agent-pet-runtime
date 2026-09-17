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

    /// When each agent's timestamp was last written to disk. The in-memory
    /// value above is always current; the file only has to be close enough
    /// that a restart does not lose the fact that events do arrive.
    private var lastPersistedAt: [String: Date] = [:]

    /// An event timestamp is written to disk at most this often per agent.
    /// A working turn emits several events per second, and none of them is
    /// worth its own atomic file write.
    public static let lastEventPersistInterval: TimeInterval = 10

    public init(
        store: IntegrationStore,
        detector: AgentDetector,
        evaluator: IntegrationHealthEvaluator = IntegrationHealthEvaluator()
    ) {
        self.store = store
        self.detector = detector
        self.evaluator = evaluator
    }

    public func statuses(transaction: ConfigTransaction) -> [AgentStatus] {
        AgentIntegrationRegistry.all(transaction: transaction).map { profile in
            status(for: profile)
        }
    }

    public func status(for profile: AgentIntegrationProfile) -> AgentStatus {
        assemble(profile: profile, detection: detector.detect(profile.detection))
    }

    /// The same status, for callers that have already run detection.
    ///
    /// The manager re-evaluates health on a timer and on every event, and
    /// detection spawns a `--version` process — so the expensive half is
    /// passed in rather than repeated.
    public func status(
        for profile: AgentIntegrationProfile,
        detection: DetectionResult
    ) -> AgentStatus {
        assemble(profile: profile, detection: detection)
    }

    private func assemble(
        profile: AgentIntegrationProfile,
        detection: DetectionResult
    ) -> AgentStatus {
        let record = store.record(for: profile.agentID)
        let lastEvent = lastEventDate(agentID: profile.agentID)

        // Only meaningful when we can actually check the file.
        var present = true
        if let configurator = profile.configurator, record.isConfigured {
            present = configurator.entriesPresent(in: record)
        }

        let health = evaluator.health(
            record: record,
            isDetected: detection.isDetected,
            lastEventAt: lastEvent,
            entriesPresent: present
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

    /// Repairs configs written by an earlier launch whose hook lines this
    /// version no longer installs.
    ///
    /// This is the safe direction for the runtime to move in on its own: an
    /// entry that was inert when it was written can start gating the agent when
    /// the agent's own contract changes underneath it, and the user has no
    /// reason to suspect a config an older version set up for them. Only lines
    /// the runtime recorded are dropped, and a configurator refuses when a
    /// human has edited inside the entry — the card's drift report is the
    /// honest answer for that case.
    ///
    /// Runs at launch, best effort, and returns one line per repaired agent for
    /// the bottom bar. `profiles` is for tests: the registry resolves against
    /// the real home directory, which is not a thing a test may write to.
    @discardableResult
    public func removeObsoleteEntries(
        transaction: ConfigTransaction,
        profiles: [AgentIntegrationProfile]? = nil,
        now: Date = Date()
    ) -> [String] {
        var notes: [String] = []

        for profile in profiles ?? AgentIntegrationRegistry.all(transaction: transaction) {
            guard let configurator = profile.configurator else { continue }
            let record = store.record(for: profile.agentID)
            guard record.isConfigured else { continue }
            guard let outcome = try? configurator.removeObsoleteEntries(record, now: now),
                  outcome.didChange
            else { continue }

            try? store.save(outcome.record)
            let dropped = Set(record.entries.map(\.event))
                .subtracting(outcome.record.entries.map(\.event))
            notes.append(
                "\(profile.displayName): removed an outdated hook line "
                + "(\(dropped.sorted().joined(separator: ", "))) — this version no longer installs it."
            )
        }
        return notes
    }

    public func recordEvent(agentID: String, at date: Date = Date()) {
        lastEventAt[agentID] = date
        persistLastEvent(agentID: agentID, at: date)
    }

    /// The most recent event from an agent, this launch or any earlier one.
    ///
    /// Both halves matter: the in-memory half is exact and current, the
    /// persisted half is what survives a restart — which is the whole point,
    /// since the app is restarted (or upgraded, which stops it) with agent
    /// sessions still open.
    public func lastEventDate(agentID: String) -> Date? {
        let persisted = store.record(for: agentID).lastEventAt
        switch (lastEventAt[agentID], persisted) {
        case let (memory?, disk?): return max(memory, disk)
        case let (memory?, nil):   return memory
        case let (nil, disk?):     return disk
        case (nil, nil):           return nil
        }
    }

    private func persistLastEvent(agentID: String, at date: Date) {
        if let last = lastPersistedAt[agentID],
           date.timeIntervalSince(last) < Self.lastEventPersistInterval {
            return
        }
        lastPersistedAt[agentID] = date

        var record = store.record(for: agentID)
        // Only agents with an integration have a card to be accurate about,
        // and an unconfigured agent has no file to write to anyway.
        guard record.isConfigured else { return }
        record.lastEventAt = date
        try? store.save(record)
    }

    /// Direct access for callers that have already run detection and do not
    /// want to spawn a `--version` process per agent on every refresh.
    public func recordFor(agentID: String) -> IntegrationRecord {
        store.record(for: agentID)
    }
}
