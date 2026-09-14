import AgentPetCore
import AppKit
import Foundation

/// Renders the pet offscreen and measures what actually lands in the buffer.
///
/// `screencapture` cannot see this app's windows without Screen Recording
/// permission, so a pixel count taken from the view's own backing store is the
/// only honest evidence that anything is being drawn. Run with
/// `AgentPet --selftest`.
@MainActor
enum RenderSelfTest {

    struct Result {
        let state: AgentState
        let trackName: String
        let opaquePixels: Int
        let totalPixels: Int
    }

    /// Draws `view` into an offscreen buffer and counts pixels with any alpha.
    static func measure(_ view: PetView) -> (opaque: Int, total: Int) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return (0, 0)
        }
        view.cacheDisplay(in: view.bounds, to: rep)

        guard let data = rep.bitmapData else { return (0, 0) }
        let samplesPerPixel = rep.samplesPerPixel
        guard samplesPerPixel >= 4 else { return (0, 0) }

        var opaque = 0
        let count = rep.pixelsWide * rep.pixelsHigh
        for index in 0..<count {
            // Alpha is the last sample in the RGBA layout AppKit hands back.
            if data[index * samplesPerPixel + 3] > 8 { opaque += 1 }
        }
        return (opaque, count)
    }

    /// A hash of what was actually drawn.
    ///
    /// Comparing renders by opaque-pixel count is not enough — two different
    /// rows can light the same number of pixels, and a count cannot tell a
    /// changed picture from an unchanged one. This compares content.
    static func contentHash(_ view: PetView) -> String {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return "no-rep"
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.bitmapData else { return "no-data" }
        return String(
            Hashing.sha256(Data(bytes: data, count: rep.bytesPerRow * rep.pixelsHigh)).prefix(12)
        )
    }

    /// What one track looks like over time, for comparing tracks against each
    /// other.
    ///
    /// Two samples, because a single one at the start of an animation is not
    /// a fair comparison: packages are commonly authored with the same neutral
    /// pose in column 0 of every row (clippit is), so every track *opens*
    /// identically and only diverges as it plays. The offset is chosen to land
    /// mid-cycle for every row in the contract, whose shortest is about a
    /// second.
    private static func trackSignature(
        _ state: AgentState,
        controller: PetController,
        view: PetView
    ) -> String {
        var samples: [String] = []
        for elapsed in [0.0, 0.42] {
            controller.previewState(state, elapsed: elapsed)
            samples.append(contentHash(view))
        }
        return samples.joined(separator: "+")
    }

    static func run(controller: PetController, view: PetView, petSize: PetSize) -> Int32 {
        print("Render self-test")
        print("")

        // With no pet installed there is nothing to render, and that is an
        // environment fact rather than a defect. Reported distinctly so a CI
        // run on a bare machine does not look like a broken build.
        guard controller.loadedProfile != nil else {
            print("  – skipped: no pet packages are installed")
            print("")
            print("SKIPPED")
            return 0
        }

        var failures = 0
        let states: [AgentState] = [.idle, .running, .waitingInput, .waitingApproval,
                                    .completed, .failed, .paused, .unknown]

        // Two states sharing a track must look identical; two states on
        // different tracks must not. Comparing raw state-to-state would flag
        // `waitingInput` and `waitingApproval` as a bug when they are in fact
        // deliberately the same animation.
        var rendersByTrack: [String: (signature: String, states: [AgentState])] = [:]

        for state in states {
            controller.previewState(state)
            guard let image = view.currentImage else {
                print("  ✗ \(state.rawValue): no image")
                failures += 1
                continue
            }

            let (opaque, total) = measure(view)
            let ratio = total > 0 ? Double(opaque) / Double(total) : 0
            let ok = opaque > 0
            if !ok { failures += 1 }

            let track = state.animationTrackName
            print(String(
                format: "  %@ %-16s -> %-9s %4dx%-4d  %6d / %6d visible px  (%.1f%%)",
                ok ? "✓" : "✗",
                (state.rawValue as NSString).utf8String!,
                (track as NSString).utf8String!,
                image.width, image.height,
                opaque, total, ratio * 100
            ))

            let signature = trackSignature(state, controller: controller, view: view)
            if var existing = rendersByTrack[track] {
                if existing.signature != signature {
                    print("      ✗ same track '\(track)' rendered differently for "
                          + "\(existing.states.map(\.rawValue)) and \(state.rawValue)")
                    failures += 1
                }
                existing.states.append(state)
                rendersByTrack[track] = existing
            } else {
                rendersByTrack[track] = (signature, [state])
            }
        }

        // Distinct tracks must produce distinct pictures.
        var seen: [String: String] = [:]
        for (track, entry) in rendersByTrack.sorted(by: { $0.key < $1.key }) {
            if let other = seen[entry.signature] {
                print("  ✗ tracks '\(other)' and '\(track)' render identically")
                failures += 1
            }
            seen[entry.signature] = track
        }

        print("")
        print("  \(rendersByTrack.count) distinct tracks rendered from \(states.count) states")

        failures += checkDraggable(view: view)
        failures += checkBehaviourLayers(controller: controller, view: view)
        failures += checkMessagePanel(controller: controller, view: view, petSize: petSize)

        print("")
        print(failures == 0 ? "PASS" : "FAIL (\(failures) problem(s))")
        return failures == 0 ? 0 : 1
    }

    /// Checks the layers above the agent state — locomotion and gaze — which
    /// the state sweep above never exercises.
    private static func checkBehaviourLayers(controller: PetController, view: PetView) -> Int {
        print("")
        print("Behaviour layers")
        var failures = 0

        // Dragging must take over from whatever the agent is doing.
        controller.previewState(.waitingInput)
        let waitingBefore = view.currentImage
        controller.beginDrag()
        controller.updateDrag(dx: 12, dy: 0)
        let draggedRight = view.currentImage
        if draggedRight != nil, draggedRight !== waitingBefore {
            print("  ✓ dragging replaces the agent state with locomotion")
        } else {
            print("  ✗ dragging did not change the animation")
            failures += 1
        }

        controller.updateDrag(dx: -12, dy: 0)
        if view.currentImage !== draggedRight {
            print("  ✓ reversing the drag switches direction")
        } else {
            print("  ✗ the pet did not turn around when dragged the other way")
            failures += 1
        }

        controller.endDrag()
        controller.clearPreview()
        if view.currentImage !== draggedRight {
            print("  ✓ releasing returns the pet to its own animation")
        } else {
            print("  ✗ the pet stayed in locomotion after the drag ended")
            failures += 1
        }

        // The pointer arriving makes the pet jump — Codex's `hovered ?
        // "jumping" : state` — and the pose it lands in is held until the
        // pointer leaves, so the picture must stay put rather than fall back
        // to the agent's row on its own.
        controller.previewState(.running)
        let workingBefore = view.currentImage
        controller.beginHover()
        let jumped = view.currentImage
        if jumped != nil, jumped !== workingBefore {
            print("  ✓ the pointer arriving plays the jump")
        } else {
            print("  ✗ hovering did not change the animation")
            failures += 1
        }

        controller.endHover()
        if view.currentImage !== jumped {
            print("  ✓ the pointer leaving hands the pet back to its own animation")
        } else {
            print("  ✗ the pet stayed on the jump after the pointer left")
            failures += 1
        }
        controller.clearPreview()

        // The introduction: the pet waves and the panel carries the words.
        // Codex shows its own for eight seconds, once per pet.
        let beforeGreeting = view.currentImage
        controller.introduce(petName: "Clippy")
        let greetingRow = view.currentPanel.rows.first
        let greetingLabel = greetingRow?.message?.label
        let greetingBody = greetingRow?.message?.body
        if greetingLabel == "Hi, I'm Clippy",
           greetingBody == "I'm here to help keep your sessions moving",
           view.currentImage !== beforeGreeting {
            print("  ✓ the pet introduces itself, and waves while it does")
        } else {
            print("  ✗ the introduction is wrong: "
                  + "\(greetingLabel ?? "no row") / \(greetingBody ?? "-")")
            failures += 1
        }

        // A row that belongs to no session must not invent the columns a
        // session row has: a blank agent name or session id reads as a bug,
        // and the pet's own line has neither.
        if let greetingRow {
            let items = MessagePanelLayout.items(for: greetingRow, config: view.currentPanelConfig)
            let sessionColumns = items.filter { $0.kind == .agent || $0.kind == .session }
            if sessionColumns.isEmpty {
                print("  ✓ the introduction carries no session's columns")
            } else {
                print("  ✗ the introduction drew a blank agent or session column")
                failures += 1
            }
        }
        // Retired before the panel checks: they count session rows, and the
        // introduction is not one.
        controller.dismissGreeting()

        // Gaze only exists in a V2 atlas. A V1 pet has nowhere to put a
        // direction, so "no effect" is the correct result rather than a fault.
        guard let profile = controller.loadedProfile else {
            controller.clearPreview()
            return failures
        }
        guard profile.hasLookDirections else {
            print("  – gaze skipped: \(profile.displayName) has no look rows "
                  + "(a V2 pet is needed)")
            controller.clearPreview()
            return failures
        }

        controller.previewState(.idle)
        let idleFrame = view.currentImage
        controller.aimGaze(at: 90)   // straight right
        if view.currentImage != nil, view.currentImage !== idleFrame {
            print("  ✓ an idle pet turns to look toward the pointer")
        } else {
            print("  ✗ gaze had no effect on a \(profile.displayName) pet")
            failures += 1
        }

        controller.aimGaze(at: nil)
        if view.currentImage !== idleFrame {
            print("  ✓ with no direction the pet falls back to idle")
        } else {
            print("  ✗ the deadzone did not fall back to idle")
            failures += 1
        }

        // Gaze must not outrank an agent that is actually doing something.
        controller.aimGaze(at: 90)
        controller.previewState(.running)
        let working = view.currentImage
        controller.previewState(.idle)
        if view.currentImage !== working {
            print("  ✓ a working agent outranks where the pointer is")
        } else {
            print("  ✗ gaze overrode an active agent state")
            failures += 1
        }

        controller.aimGaze(at: nil)
        controller.clearPreview()
        return failures
    }

    /// Verifies the message panel beside the pet: the rows, the space they
    /// reserve, the window that grows for them, and the usage bar.
    ///
    /// Driven by real events through the real engine — the panel is a view of
    /// the activity list, and a test that hand-built the rows would prove
    /// nothing about whether sessions reach it.
    private static func checkMessagePanel(controller: PetController, view: PetView, petSize: PetSize) -> Int {
        print("")
        print("Message panel")
        var failures = 0
        let now = Date()
        let confidence = EventConfidence(level: .high, source: "selftest")

        func send(
            _ kind: AgentEventKind, agent: String, session: String, at offset: TimeInterval,
            tool: String? = nil, context: SessionContext? = nil
        ) {
            controller.ingest(AgentEvent(
                agentID: agent,
                sessionID: session,
                kind: kind,
                at: now.addingTimeInterval(offset),
                confidence: confidence,
                toolName: tool,
                focusTarget: .openingDirectory(URL(fileURLWithPath: "/tmp/project")),
                context: context
            ))
        }

        // Two agents, one of them blocked — the case the whole panel exists
        // for. The blocked one arrives first so the focus lands on it without
        // waiting out the engine's anti-flicker hold, which is deliberately
        // three seconds long and not something a test should sleep through.
        send(.waitingApproval, agent: "claude-code", session: "cafebabe-2222", at: 0,
             tool: "Write",
             context: SessionContext(usedPercent: 72, totalTokens: 144_000,
                                     windowSize: 200_000, modelName: "Opus 4.6",
                                     effortLevel: "high", costUSD: 3.42,
                                     fiveHourPercent: 41, sevenDayPercent: 12,
                                     capturedAt: now))
        send(.working, agent: "codex", session: "deadbeef-1111", at: 1, tool: "Bash")

        let panel = view.currentPanel
        guard panel.rows.count == 2 else {
            print("  ✗ expected a row per session, got \(panel.rows.count)")
            controller.resetActivities()
            return failures + 1
        }
        print("  ✓ \(panel.rows.count) sessions, one row each")

        // The blocked session is the one whose row is marked as being shown.
        if let focused = panel.rows.first(where: { $0.isFocused }),
           focused.agentName == "Claude Code" {
            print("  ✓ the blocked session is the row the pet is showing")
        } else {
            print("  ✗ the wrong session is marked as shown")
            failures += 1
        }

        let claude = panel.rows.first { $0.agentID == "claude-code" }
        if claude?.sessionSuffix == "e-2222", claude?.message?.label == "Needs input",
           claude?.context?.usedPercent == 72, claude?.task == "project" {
            print("  ✓ the row carries the session suffix, wording, context, and project")
        } else {
            print("  ✗ row contents are wrong: "
                  + "\(claude.map { "\($0.sessionSuffix) / \($0.message?.label ?? "-") / \($0.task ?? "-")" } ?? "missing")")
            failures += 1
        }

        // A tool is only "current" while the session is working.
        let codex = panel.rows.first { $0.agentID == "codex" }
        if codex?.tool == "Bash", claude?.tool == nil {
            print("  ✓ the tool is shown while working, and dropped when blocked")
        } else {
            print("  ✗ tool visibility is wrong")
            failures += 1
        }

        // Positions and sizes, as the window sees them.
        let plan = MessagePanelLayout.plan(for: panel, config: view.currentPanelConfig)
        let pet = PetWindow.size(for: petSize)
        let configuredWidth = MessagePanelLayout.panelWidth(
            for: view.currentPanelConfig, petWidth: pet.width
        )
        let withPanel = contentHash(view)
        if plan.height > 0, view.spriteRect.height < view.bounds.height {
            print("  ✓ the pet keeps its place: \(Int(plan.height))pt reserved above it")
        } else {
            print("  ✗ the panel was drawn over the pet instead of beside it")
            failures += 1
        }

        if let window = view.window,
           abs(window.frame.height - (pet.height + plan.height)) < 1,
           abs(window.frame.width - configuredWidth) < 1 {
            print("  ✓ the window is \(Int(window.frame.width))x\(Int(window.frame.height)) "
                  + "— the width the settings asked for")
        } else {
            print("  ✗ the window is wrong: "
                  + "\(view.window.map { "\($0.frame.width)x\($0.frame.height)" } ?? "no window") "
                  + "wanting \(configuredWidth) wide")
            failures += 1
        }

        // The width and alignment settings have to reach the picture. Width is
        // checked as arithmetic — the window-level check above already went
        // through the real resize path — and alignment by what is drawn.
        var narrow = view.currentPanelConfig
        narrow.widthPercent = 110
        let narrowWidth = MessagePanelLayout.panelWidth(for: narrow, petWidth: pet.width)
        if abs(narrowWidth - pet.width * 1.1) <= 1,
           MessagePanelLayout.panelWidth(for: view.currentPanelConfig, petWidth: pet.width) > narrowWidth {
            print("  ✓ the width setting is a percentage of the pet: 110% → \(Int(narrowWidth))pt")
        } else {
            print("  ✗ the width setting does not follow the pet's width")
            failures += 1
        }

        // Alignment needs room to show: with every item switched on the rows
        // fill the panel edge to edge — which is what a 200%-of-the-pet panel
        // is at Codex's pet size — and left and right would lay out the same
        // pixels. One short row is the case the setting is actually for.
        var roomToSpare = view.currentPanelConfig
        roomToSpare.items = [MessagePanelConfig.Item(.agent), MessagePanelConfig.Item(.message)]
        view.show(panel, config: roomToSpare)
        let leftHash = contentHash(view)

        var rightAligned = roomToSpare
        rightAligned.alignment = .right
        view.show(panel, config: rightAligned)
        let rightHash = contentHash(view)
        view.show(panel, config: view.currentPanelConfig)
        if rightHash != leftHash {
            print("  ✓ the alignment setting moves the rows")
        } else {
            print("  ✗ alignment changed nothing")
            failures += 1
        }

        // The context item is only drawn when a status line has reported one:
        // taking it away must change the picture.
        var withoutContext = view.currentPanelConfig
        if let index = withoutContext.items.firstIndex(where: { $0.kind == .context }) {
            withoutContext.items[index].isEnabled = false
        }
        view.show(panel, config: withoutContext)
        let withoutContextHash = contentHash(view)
        view.show(panel, config: view.currentPanelConfig)
        if withoutContextHash != withPanel {
            print("  ✓ the usage bar is actually painted")
        } else {
            print("  ✗ turning the context item off changed nothing")
            failures += 1
        }

        // The other status-line items draw from the same reading. They get a
        // row with room for them: at Codex's pet size a panel carrying every
        // item is full edge to edge, and an item squeezed out entirely would
        // make "turning it off changed nothing" the wrong verdict.
        var statusItems = MessagePanelConfig()
        statusItems.items = [MessagePanelConfig.Item(.session), MessagePanelConfig.Item(.model),
                             MessagePanelConfig.Item(.cost), MessagePanelConfig.Item(.limits)]
        view.show(panel, config: statusItems)
        let withStatusHash = contentHash(view)

        var withoutStatusItems = statusItems
        for index in withoutStatusItems.items.indices
        where [.model, .cost, .limits].contains(withoutStatusItems.items[index].kind) {
            withoutStatusItems.items[index].isEnabled = false
        }
        view.show(panel, config: withoutStatusItems)
        let withoutModelHash = contentHash(view)
        view.show(panel, config: view.currentPanelConfig)
        if withoutModelHash != withStatusHash {
            print("  ✓ the model, cost, and rate-limit items are painted too")
        } else {
            print("  ✗ the model / cost / limits items made no difference")
            failures += 1
        }

        // And an empty panel must give the space back.
        controller.resetActivities()
        let cleared = contentHash(view)
        if cleared != withPanel, view.spriteRect.height == view.bounds.height {
            print("  ✓ clearing the sessions takes the panel down")
        } else {
            print("  ✗ the panel outlived its sessions")
            failures += 1
        }

        return failures
    }

    /// Verifies the view will actually receive the click that starts a drag.
    ///
    /// Worth checking mechanically: the pet renders perfectly whether or not
    /// this works, and the failure mode is silent — a pet that animates but
    /// cannot be moved reads as a broken app with no visible cause.
    private static func checkDraggable(view: PetView) -> Int {
        print("")
        print("Drag readiness")
        var failures = 0

        // An accessory app is essentially never active, so without this the
        // first click would be spent activating and never reach the view.
        if view.acceptsFirstMouse(for: nil) {
            print("  ✓ acceptsFirstMouse — a click from another app reaches the pet")
        } else {
            print("  ✗ acceptsFirstMouse is false — the first click would be swallowed")
            failures += 1
        }

        // The centre of the view must be grabbable.
        let centre = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        if view.hitTest(centre) === view {
            print("  ✓ hitTest returns the pet at its centre")
        } else {
            print("  ✗ hitTest does not return the pet at its centre — it cannot be grabbed")
            failures += 1
        }

        // …and just outside it must pass clicks through, or the pet would
        // steal clicks meant for whatever is behind it.
        let outside = NSPoint(x: view.bounds.maxX + 20, y: view.bounds.midY)
        if view.hitTest(outside) == nil {
            print("  ✓ clicks outside the pet pass through to what is behind it")
        } else {
            print("  ✗ the pet captures clicks outside its own bounds")
            failures += 1
        }

        // Grab geometry must survive a round trip.
        let origin = CGPoint(x: 800, y: 300)
        let grab = WindowDrag.grabOffset(mouse: CGPoint(x: 850, y: 380), windowOrigin: origin)
        let returned = WindowDrag.origin(mouse: CGPoint(x: 850, y: 380), grabOffset: grab)
        if returned == origin {
            print("  ✓ drag geometry returns the window to its start")
        } else {
            print("  ✗ drag geometry drifts: \(origin) -> \(returned)")
            failures += 1
        }

        return failures
    }
}
