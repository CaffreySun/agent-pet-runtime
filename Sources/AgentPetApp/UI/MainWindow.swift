import AgentPetCore
import AppKit
import SwiftUI

/// The four top-level sections, matching the information architecture in the
/// design.
enum ManagerSection: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case pets = "Pets"
    case agents = "Agents"
    case settings = "Settings"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .activity: return "waveform.path.ecg"
        case .pets:     return "pawprint"
        case .agents:   return "cpu"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindowView: View {
    @ObservedObject var model: AgentPetModel
    @State private var section: ManagerSection = .activity

    var body: some View {
        NavigationSplitView {
            List(ManagerSection.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
        } detail: {
            VStack(spacing: 0) {
                content
                if let error = model.errorMessage {
                    banner(error, color: .red, symbol: "exclamationmark.triangle.fill")
                } else if let status = model.statusMessage {
                    banner(status, color: .secondary, symbol: "info.circle")
                }
            }
            .navigationTitle(section.rawValue)
        }
        .frame(minWidth: 760, minHeight: 520)
        .onAppear { model.refreshAll() }
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .activity: ActivityView(model: model)
        case .pets:     PetsView(model: model)
        case .agents:   AgentsView(model: model)
        case .settings: SettingsView(model: model)
        }
    }

    private func banner(_ text: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(text).lineLimit(3)
            Spacer()
            Button {
                model.errorMessage = nil
                model.statusMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
        }
        .font(.callout)
        .foregroundStyle(color)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }
}

/// Hosts the manager window.
///
/// A separate window rather than a popover: the pet stays on screen while the
/// user is in here, so changes are visible as they are made.
@MainActor
final class MainWindowController {

    private var window: NSWindow?
    private let model: AgentPetModel

    init(model: AgentPetModel) {
        self.model = model
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: MainWindowView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Agent Pet Runtime"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 860, height: 580))
        window.center()
        window.isReleasedWhenClosed = false
        // Bring the manager forward on whatever the user is actually looking
        // at, rather than on the pet's screen.
        window.collectionBehavior = [.moveToActiveSpace]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }
}
