import AgentPetCore
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: PetWindow!
    private var petView: PetView!
    private let controller = PetController()

    private let bridge = BridgeCoordinator()

    private var statusItem: NSStatusItem?
    private var library: [PetLibrary.Entry] = []
    private var selectedPetID: String?
    private var model: AgentPetModel?
    private var managerWindow: MainWindowController?

    private static let positionKey = "pet.window.origin"

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        buildStatusItem()
        var firstFrame = true
        controller.onFrame = { [weak self] image in
            if firstFrame, CommandLine.arguments.contains("--verbose") {
                firstFrame = false
                FileHandle.standardError.write(Data(
                    "[pet] first frame delivered: \(image.map { "\($0.width)x\($0.height)" } ?? "nil")\n".utf8
                ))
            }
            self?.petView.show(image)
        }

        library = PetLibrary.discover()
        if let first = library.first {
            select(pet: first)
        } else {
            presentNoPets()
        }

        controller.start()
        startBridge()
        buildModel()
        rebuildMenu()

        if CommandLine.arguments.contains("--selftest") {
            let status = RenderSelfTest.run(controller: controller, view: petView)
            exit(status)
        }

        // Builds the manager window on launch so a crash in the view hierarchy
        // shows up in a smoke test rather than the first time a user opens it.
        if CommandLine.arguments.contains("--open-manager") {
            openManager()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
        bridge.stop()
        savePosition()
    }

    private func startBridge() {
        bridge.onEvent = { [weak self] event in
            guard let self else { return }
            self.controller.ingest(event)
            self.model?.noteEvent(agentID: event.agentID)
            self.pushActivities()

            if CommandLine.arguments.contains("--verbose") {
                FileHandle.standardError.write(Data(
                    "[bridge] \(event.agentID) \(event.kind.rawValue) session=\(event.sessionID)\n".utf8
                ))
            }
        }
        bridge.onStatusChange = { [weak self] in
            self?.rebuildMenu()
        }
        bridge.start()
    }

    private func buildModel() {
        let model = AgentPetModel(
            root: BridgeSocketLocation.applicationSupportDirectory,
            shimPath: shimPath
        )
        model.onUsePet = { [weak self] pet in
            self?.loadPet(at: pet.root, name: pet.metadata.displayName)
        }
        model.onTestEvent = { [weak self] event in
            self?.controller.ingest(event)
            self?.pushActivities()
        }
        model.bridgeSummary = { [weak self] in
            guard let bridge = self?.bridge else {
                return DiagnosticsBundle.BridgeSummary(
                    isListening: false, socketPath: "", eventsReceived: 0, malformedFrames: 0
                )
            }
            return DiagnosticsBundle.BridgeSummary(
                isListening: bridge.status.isListening,
                socketPath: bridge.status.socketPath,
                eventsReceived: bridge.status.receivedCount,
                malformedFrames: bridge.malformedFrameCount
            )
        }
        self.model = model
        self.managerWindow = MainWindowController(model: model)
        pushActivities()
    }

    /// Hands the manager window the engine's current view of the world.
    private func pushActivities() {
        guard let model else { return }
        let activities = controller.currentActivities
        let focused = controller.focusedActivity
        model.updateActivities(activities, focusedID: focused?.id)
    }

    /// Loads a pet package by path. Shared by the menu and the manager window
    /// so both go through one code path.
    private func loadPet(at root: URL, name: String) {
        do {
            let loaded = try PetPackageLoader().load(from: root)
            try controller.load(loaded)
            controller.loadedPetName = name
            selectedPetID = loaded.definition.id
            model?.currentPetID = loaded.definition.id
            rebuildMenu()
        } catch {
            NSLog("Failed to load pet at \(root.path): \(error)")
        }
    }

    @objc private func openManager() {
        model?.refreshAll()
        managerWindow?.show()
    }

    // MARK: - Window

    private func buildWindow() {
        let size = PetWindow.defaultSize
        let origin = restoredOrigin() ?? defaultOrigin(for: size)
        window = PetWindow(contentRect: NSRect(origin: origin, size: size))

        petView = PetView(frame: NSRect(origin: .zero, size: size))
        petView.autoresizingMask = [.width, .height]
        petView.onDrag = { [weak self] delta in
            guard let self, let window = self.window else { return }
            var frame = window.frame
            frame.origin.x += delta.x
            frame.origin.y += delta.y
            window.setFrame(frame, display: true)
        }
        window.contentView = petView
        window.orderFrontRegardless()

        // Draw logging is its own flag: it fires sixty times a second and
        // would bury every other diagnostic.
        PetView.isLoggingFrames = CommandLine.arguments.contains("--verbose-draw")
        if CommandLine.arguments.contains("--verbose") {
            let frame = window.frame
            let onScreen = NSScreen.screens.contains { $0.frame.intersects(frame) }
            FileHandle.standardError.write(Data("""
                [pet] window frame=\(frame) visible=\(window.isVisible) \
                onAnyScreen=\(onScreen) screen=\(String(describing: window.screen?.frame)) \
                level=\(window.level.rawValue) alpha=\(window.alphaValue)

                """.utf8))
        }
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.screens.first else { return NSPoint(x: 100, y: 100) }
        return PetWindow.defaultOrigin(on: screen)
    }

    private func restoredOrigin() -> NSPoint? {
        guard let saved = UserDefaults.standard.string(forKey: Self.positionKey) else { return nil }
        let parts = saved.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        let point = NSPoint(x: parts[0], y: parts[1])
        // A pet restored onto a monitor that is no longer attached would be
        // invisible and unreachable.
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(
            NSRect(origin: point, size: PetWindow.defaultSize)
        ) }) else { return nil }
        return point
    }

    private func savePosition() {
        guard let origin = window?.frame.origin else { return }
        UserDefaults.standard.set("\(origin.x),\(origin.y)", forKey: Self.positionKey)
    }

    private func presentNoPets() {
        let alert = NSAlert()
        alert.messageText = "No pet packages found"
        alert.informativeText = """
            Looked in:
            \(PetLibrary.searchPaths.map { "  \($0.path)" }.joined(separator: "\n"))
            """
        alert.alertStyle = .informational
        alert.runModal()
    }

    // MARK: - Menu

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🐾"
        statusItem = item
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Agent Pet Runtime", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let openItem = NSMenuItem(title: "Open Pet Manager…",
                                  action: #selector(openManager), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)
        menu.addItem(.separator())

        // Pets
        let petsItem = NSMenuItem(title: "Pet", action: nil, keyEquivalent: "")
        let petsMenu = NSMenu()
        for entry in library {
            let item = NSMenuItem(title: entry.name, action: #selector(choosePet(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.root.path
            item.state = (entry.definition.id == selectedPetID) ? .on : .off
            petsMenu.addItem(item)
            if !entry.warnings.isEmpty {
                let warning = NSMenuItem(
                    title: "  ⚠︎ \(entry.warnings.count) compatibility warning(s)",
                    action: nil, keyEquivalent: ""
                )
                warning.isEnabled = false
                petsMenu.addItem(warning)
            }
        }
        if library.isEmpty { petsMenu.addItem(withTitle: "None found", action: nil, keyEquivalent: "") }
        petsItem.submenu = petsMenu
        menu.addItem(petsItem)

        // Animation preview — same resolver the desktop pet uses.
        let previewItem = NSMenuItem(title: "Preview Animation", action: nil, keyEquivalent: "")
        let previewMenu = NSMenu()
        for track in CompatibilityProfile.openAICodexV1.tracks {
            let item = NSMenuItem(title: track.name, action: #selector(previewTrack(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = track.name
            previewMenu.addItem(item)
        }
        previewItem.submenu = previewMenu
        menu.addItem(previewItem)

        // Synthetic agent events — the "Test Integration" path from the spec,
        // exercised through the real activity engine.
        let simulateItem = NSMenuItem(title: "Simulate Agent Event", action: nil, keyEquivalent: "")
        let simulateMenu = NSMenu()
        for kind in AgentEventKind.allCases {
            let item = NSMenuItem(title: kind.rawValue, action: #selector(simulateEvent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            simulateMenu.addItem(item)
        }
        simulateMenu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Activities", action: #selector(clearActivities), keyEquivalent: "")
        clear.target = self
        simulateMenu.addItem(clear)
        simulateItem.submenu = simulateMenu
        menu.addItem(simulateItem)

        // Bridge status — the first thing to look at when the pet is not
        // reacting to a real agent.
        let bridgeItem = NSMenuItem(title: "Event Bridge", action: nil, keyEquivalent: "")
        let bridgeMenu = NSMenu()

        let state = NSMenuItem(
            title: bridge.status.isListening ? "● Listening" : "○ Not listening",
            action: nil, keyEquivalent: ""
        )
        state.isEnabled = false
        bridgeMenu.addItem(state)

        let socket = NSMenuItem(title: "  \(bridge.status.socketPath)", action: nil, keyEquivalent: "")
        socket.isEnabled = false
        bridgeMenu.addItem(socket)

        let received = NSMenuItem(
            title: "  \(bridge.status.receivedCount) event(s) received",
            action: nil, keyEquivalent: ""
        )
        received.isEnabled = false
        bridgeMenu.addItem(received)

        if let error = bridge.status.error {
            let failure = NSMenuItem(title: "  ⚠︎ \(error)", action: nil, keyEquivalent: "")
            failure.isEnabled = false
            bridgeMenu.addItem(failure)
        }

        if !bridge.recent.isEmpty {
            bridgeMenu.addItem(.separator())
            for recent in bridge.recent.prefix(8) {
                let kind = recent.kind?.rawValue ?? "(unmapped)"
                let item = NSMenuItem(
                    title: "  \(recent.agentID) · \(recent.eventName) → \(kind)",
                    action: nil, keyEquivalent: ""
                )
                item.isEnabled = false
                bridgeMenu.addItem(item)
            }
        }

        bridgeMenu.addItem(.separator())
        let copySetup = NSMenuItem(title: "Copy Hook Setup…", action: #selector(copyHookSetup), keyEquivalent: "")
        copySetup.target = self
        bridgeMenu.addItem(copySetup)

        bridgeItem.submenu = bridgeMenu
        menu.addItem(bridgeItem)

        menu.addItem(.separator())

        let activityItem = NSMenuItem(title: activitySummary(), action: nil, keyEquivalent: "")
        activityItem.isEnabled = false
        menu.addItem(activityItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    private func activitySummary() -> String {
        let activities = controller.currentActivities
        guard !activities.isEmpty else { return "No active sessions" }
        return activities
            .map { "\($0.agentID): \($0.state.rawValue)" }
            .joined(separator: ", ")
    }

    // MARK: - Actions

    private func select(pet entry: PetLibrary.Entry) {
        loadPet(at: entry.root, name: entry.name)
    }

    @objc private func choosePet(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let entry = library.first(where: { $0.root.path == path })
        else { return }
        select(pet: entry)
        rebuildMenu()
    }

    @objc private func previewTrack(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        controller.playGesture(named: name)
    }

    @objc private func simulateEvent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let kind = AgentEventKind(rawValue: raw)
        else { return }

        controller.ingest(AgentEvent(
            agentID: "test-agent",
            sessionID: "test-session",
            kind: kind,
            at: Date(),
            confidence: EventConfidence(level: .high, source: "test"),
            summary: "Synthetic \(raw) event"
        ))
        rebuildMenu()
    }

    @objc private func clearActivities() {
        controller.resetActivities()
        rebuildMenu()
    }

    /// The shim ships beside the app executable, so the running binary's own
    /// location is the reliable way to find it.
    private var shimPath: String {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath()
        let sibling = executable.deletingLastPathComponent()
            .appendingPathComponent("agentpet-hook")
        return FileManager.default.isExecutableFile(atPath: sibling.path)
            ? sibling.path
            : "/path/to/agentpet-hook"
    }

    /// Writes a ready-to-paste Claude Code hook block to the clipboard.
    ///
    /// Deliberately a copy rather than an automatic edit. The runtime holds
    /// itself to backup → modify → validate → rollback before touching
    /// anyone's agent config, and that transaction is not built yet. Handing
    /// the user the exact block is honest about what has been proven.
    @objc private func copyHookSetup() {
        let json = HookSetup.claudeCodeJSON(shimPath: shimPath)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(json, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Claude Code hook configuration copied"
        alert.informativeText = """
            Paste the "hooks" block into ~/.claude/settings.json, then restart \
            Claude Code.

            Shim: \(shimPath)

            Back up that file first — the runtime does not yet have its \
            backup/rollback transaction, so this is a manual edit.
            """
        alert.alertStyle = .informational
        alert.runModal()
    }
}
