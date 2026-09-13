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
