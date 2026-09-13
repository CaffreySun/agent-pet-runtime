import AgentPetCore
import AppKit
import SwiftUI

struct SettingsView: View {

    @ObservedObject var model: AgentPetModel
    @State private var launchAtLogin = LaunchAtLogin.state

    var body: some View {
        Form {
            Section("Pet") {
                Toggle("Animate the pet", isOn: binding(\.pet.animationEnabled))
                Toggle("Keep the pet above other windows", isOn: binding(\.pet.alwaysOnTop))
                Toggle("Respect Reduce Motion", isOn: binding(\.pet.respectsReduceMotion))
                    .help("When the system asks apps to reduce motion, hold the pet on its idle frame.")
            }

            Section("Agents") {
                Toggle("Configure new agents automatically",
                       isOn: binding(\.agents.autoConfigureNewAgents))
                    .help("Off by default: software that edits agent configuration without asking is software you cannot trust.")
            }

            messagePanelSection

            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isOn },
                    set: { newValue in
                        launchAtLogin = LaunchAtLogin.setEnabled(newValue)
                    }
                ))
                if let explanation = launchAtLogin.explanation {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Diagnostics") {
                Toggle("Keep a state transition log", isOn: binding(\.diagnostics.loggingEnabled))
                HStack {
                    Button("Export Diagnostics…") { exportDiagnostics() }
                    Text("Contains versions, integration status, and state transitions. Never prompts, model output, credentials, or source.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Reveal Support Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            BridgeSocketLocation.applicationSupportDirectory
                        ])
                    }
                    Text(BridgeSocketLocation.applicationSupportDirectory.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LaunchAtLogin.state }
    }

    // MARK: - Message panel

    private var messagePanelSection: some View {
        Section("Pet message panel") {
            Toggle("Always show the panel", isOn: binding(\.messagePanel.alwaysVisible))
                .help("On: the panel is there whenever a session is known. "
                      + "Off: it appears only while something is actually happening.")

            ForEach(Array(model.config.messagePanel.items.enumerated()), id: \.element.kind) { index, item in
                HStack(spacing: 8) {
                    Toggle(item.kind.title, isOn: itemEnabledBinding(index))
                        .help(item.kind.explanation)
                    Spacer()
                    Button {
                        moveItem(from: index, by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == 0)
                    .help("Move left")
                    Button {
                        moveItem(from: index, by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .disabled(index == model.config.messagePanel.items.count - 1)
                    .help("Move right")
                }
            }

            HStack {
                Text(contextTapSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                switch model.contextTap {
                case .notInstalled:
                    Button("Enable Context Usage…") { model.enableContextTap() }
                case .installed:
                    Button("Stop Using the Status Line") { model.disableContextTap() }
                case .drifted:
                    Button("Re-enable Context Usage…") { model.enableContextTap() }
                }
            }
        }
        .onAppear { model.refreshContextTap() }
    }

    private var contextTapSummary: String {
        switch model.contextTap {
        case .notInstalled:
            return "Context usage is not available yet: Claude Code only reports it to its "
                + "status line. Enabling wraps your status line — the runtime reads the "
                + "numbers, then runs your own command unchanged."
        case .installed(let original):
            return original == nil || original!.isEmpty
                ? "Reading context usage from Claude Code’s status line."
                : "Reading context usage from Claude Code’s status line, and running yours through it unchanged."
        case .drifted:
            return "The status line in ~/.claude/settings.json is no longer the one the runtime "
                + "installed — something else changed it. Re-enabling wraps whatever is there now."
        }
    }

    private func itemEnabledBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: {
                guard model.config.messagePanel.items.indices.contains(index) else { return false }
                return model.config.messagePanel.items[index].isEnabled
            },
            set: { newValue in
                guard model.config.messagePanel.items.indices.contains(index) else { return }
                model.config.messagePanel.items[index].isEnabled = newValue
                model.saveConfig()
            }
        )
    }

    private func moveItem(from index: Int, by offset: Int) {
        let target = index + offset
        var items = model.config.messagePanel.items
        guard items.indices.contains(index), items.indices.contains(target) else { return }
        items.swapAt(index, target)
        model.config.messagePanel.items = items
        model.saveConfig()
    }

    /// Settings are written on change, so there is no Save button to forget.
    private func binding<T>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(
            get: { model.config[keyPath: keyPath] },
            set: { newValue in
                model.config[keyPath: keyPath] = newValue
                model.saveConfig()
            }
        )
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "agent-pet-diagnostics.json"
        panel.message = "Save a diagnostics bundle to share with a bug report"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.exportDiagnostics(to: url)
    }
}
