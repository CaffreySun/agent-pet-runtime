import Foundation

/// Events a shim could not deliver because the runtime was not running.
///
/// The shim is on the agent's critical path, so it must never wait and never
/// fail — when the app was not listening, an event used to be dropped on the
/// floor. That is right at the moment of the drop and wrong at the next
/// launch: quit-and-relaunch, and especially a Homebrew upgrade (which stops
/// the old app before replacing it), leaves every open session mute. The pet
/// came back from an upgrade knowing nothing about the session that was
/// mid-turn seconds earlier, and only learned about it at that session's next
/// hook — which for a long tool is minutes away, with several sessions open
/// it is only ever a subset that reports in.
///
/// So an undeliverable event is written down instead, and the next launch
/// replays it through the ordinary bridge path before the user sees anything.
///
/// The spool is on disk, so it is held to the project's standing rule: what
/// is written is first reduced by `EventCapture.sanitizedPayload` — session
/// id, working directory, event name, tool *name*, notification type — never
/// prompts, tool arguments, tool output, or model output. Files are written
/// owner-only, capped in number, and deleted as soon as they have been read.
public enum EventSpool {

    /// How many undelivered events are kept. A working turn emits a few per
    /// tool call; two hundred covers a long absence without letting a machine
    /// where the app is never launched again accumulate files forever.
    public static let maximumEvents = 200

    public static var defaultDirectory: URL {
        BridgeSocketLocation.applicationSupportDirectory.appendingPathComponent("pending-events")
    }

    /// Writes one event, reduced, for the next launch to pick up.
    ///
    /// Never throws and never blocks for long: if any of this fails, the
    /// event is dropped exactly as it would have been before this existed.
    @discardableResult
    public static func write(
        _ envelope: BridgeEnvelope,
        to directory: URL = defaultDirectory,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let data = try? reduced(envelope).encoded() else { return false }

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }

        prune(directory: directory, fileManager: fileManager)

        // The timestamp leads the name so listing the directory is roughly
        // chronological, and so pruning can drop the oldest without reading
        // every file.
        //
        // Padded by hand rather than with `%016d`: that specifier reads a
        // 32-bit argument, and a millisecond timestamp does not fit in one —
        // it silently wrapped to a negative number, which sorted the newest
        // events first and made pruning delete exactly the wrong ones.
        let millis = String(Int(envelope.receivedAt.timeIntervalSince1970 * 1000))
        let stamp = String(repeating: "0", count: max(0, 16 - millis.count)) + millis
        let name = "\(stamp)-\(UUID().uuidString).json"
        let url = directory.appendingPathComponent(name)

        // Created with the mode baked in rather than written atomically: an
        // atomic write renames a temporary file into place, and the temporary
        // file's permissions are the process umask's, not ours.
        return fileManager.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        )
    }

    /// Replays everything waiting, oldest first, and deletes each file once
    /// its event has been handed over.
    ///
    /// Returns how many events were replayed. A file that cannot be decoded is
    /// removed rather than left to fail again on every future launch.
    @discardableResult
    public static func drain(
        from directory: URL = defaultDirectory,
        fileManager: FileManager = .default,
        handler: (BridgeEnvelope) -> Void
    ) -> Int {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        var queued: [(URL, BridgeEnvelope)] = []

        for name in names.sorted() where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            let envelope = (try? Data(contentsOf: url))
                .flatMap { try? BridgeEnvelope.decode(from: $0) }
            guard let envelope else {
                try? fileManager.removeItem(at: url)
                continue
            }
            queued.append((url, envelope))
        }

        // Sorted by when they happened rather than by name, so a clock change
        // or a file copied in by hand cannot replay a session's events backwards.
        queued.sort { $0.1.receivedAt < $1.1.receivedAt }

        for (url, envelope) in queued {
            handler(envelope)
            try? fileManager.removeItem(at: url)
        }
        return queued.count
    }

    public static func pendingCount(
        in directory: URL = defaultDirectory,
        fileManager: FileManager = .default
    ) -> Int {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.count
    }

    // MARK: - Internals

    /// The envelope with its payload reduced to the capturable keys.
    ///
    /// Keeping the envelope shape (agent, event name, time, process info)
    /// means a replayed event takes the same path as a live one, down to the
    /// session-id fallback for payloads that never had a session id.
    static func reduced(_ envelope: BridgeEnvelope) -> BridgeEnvelope {
        let kept = EventCapture.sanitizedPayload(envelope.rawPayload)
        let payload = (try? JSONSerialization.data(withJSONObject: kept)) ?? Data()
        return BridgeEnvelope(
            agentID: envelope.agentID,
            eventName: envelope.eventName,
            receivedAt: envelope.receivedAt,
            proc: envelope.proc,
            rawPayload: payload,
            shimVersion: envelope.shimVersion,
            version: envelope.v
        )
    }

    /// Keeps the directory at or under the cap by deleting the oldest files.
    private static func prune(directory: URL, fileManager: FileManager) {
        let names = ((try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .sorted()
        guard names.count >= maximumEvents else { return }
        for name in names.prefix(names.count - maximumEvents + 1) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}
