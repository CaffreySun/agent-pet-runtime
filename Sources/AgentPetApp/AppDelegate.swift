import AgentPetCore
import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: PetWindow!
    private var petView: PetView!
    private let controller = PetController()

    private var statusItem: NSStatusItem?
    private var library: [PetLibrary.Entry] = []
    private var selectedPetID: String?

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
        rebuildMenu()

        if CommandLine.arguments.contains("--selftest") {
            let status = RenderSelfTest.run(controller: controller, view: petView)
            exit(status)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
        savePosition()
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

        PetView.isLoggingFrames = CommandLine.arguments.contains("--verbose")
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
        do {
            let loaded = try PetLibrary.load(entry)
            try controller.load(loaded)
            controller.loadedPetName = entry.name
            selectedPetID = entry.definition.id
        } catch {
            NSLog("Failed to load pet \(entry.name): \(error)")
        }
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
}
