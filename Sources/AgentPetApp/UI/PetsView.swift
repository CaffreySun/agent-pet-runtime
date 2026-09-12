import AgentPetCore
import AppKit
import SwiftUI

/// Pet Manager: what is installed, and how to add more.
struct PetsView: View {

    @ObservedObject var model: AgentPetModel
    @State private var sprites: [String: SpriteFrames] = [:]
    @State private var selection: InstalledPet?
    @State private var previewTrack = "idle"

    private let previewTracks = ["idle", "running", "waiting", "waving", "failed", "review"]

    var body: some View {
        HSplitView {
            installedList
                .frame(minWidth: 260, idealWidth: 300)
            detail
                .frame(minWidth: 340)
        }
        .task { loadSprites() }
    }

    // MARK: - List

    private var installedList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Installed")
                    .font(.headline)
                Spacer()
                Button {
                    importFromDisk()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Import a pet package folder")
            }
            .padding(10)

            Divider()

            if model.installedPets.isEmpty {
                emptyState
            } else {
                List(model.installedPets, selection: $selection) { pet in
                    row(for: pet).tag(pet)
                }
            }

            if !model.availablePets.isEmpty {
                Divider()
                Text("Found in ~/.codex/pets")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)
                List(availablePets) { pet in
                    availableRow(pet)
                }
                .frame(height: 120)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No pets installed")
                .foregroundStyle(.secondary)
            Text("Import a package folder, or import one of the pets Codex already has.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func row(for pet: InstalledPet) -> some View {
        HStack(spacing: 10) {
            preview(for: pet, track: "idle", size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(pet.metadata.displayName).fontWeight(.medium)
                Text(pet.id)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if pet.id == currentPetID {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .help("Currently on the desktop")
            }
        }
        .padding(.vertical, 2)
    }

    private func availableRow(_ pet: AgentPetModel.AvailablePet) -> some View {
        HStack {
            Text(pet.name)
                .font(.callout)
            Spacer()
            if pet.alreadyInstalled {
                Text("Imported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Import") { model.importAvailable(pet) }
                    .buttonStyle(.link)
            }
        }
    }

    private var availablePets: [AgentPetModel.AvailablePet] { model.availablePets }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let pet = selection {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    preview(for: pet, track: previewTrack, size: 220)
                        .frame(maxWidth: .infinity)
                        .frame(height: 240)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))

                    Picker("Animation", selection: $previewTrack) {
                        ForEach(previewTracks, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(pet.metadata.displayName).font(.title2)
                        Text(pet.definition.description)
                            .foregroundStyle(.secondary)
                    }

                    infoGrid(for: pet)
                    actions(for: pet)
                }
                .padding(16)
            }
        } else {
            VStack {
                Text("Select a pet")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func infoGrid(for pet: InstalledPet) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("ID", pet.id)
            row("Profile", pet.metadata.compatibilityProfile)
            row("Source", pet.metadata.provenance.kind.rawValue)
            if let origin = pet.metadata.provenance.originalSourcePath {
                row("Imported from", origin)
            }
            row("Installed", pet.metadata.provenance.installedAt.formatted(date: .abbreviated, time: .shortened))
            row("Managed", pet.isManagedByRuntime ? "Yes — uninstall removes it" : "No — files are left alone")
            if pet.definition.profile != .openAICodexV1 {
                row("Note", "Rows beyond the V1 set are not played")
            }
        }
        .font(.callout)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }

    private func actions(for pet: InstalledPet) -> some View {
        HStack {
            Button("Use on Desktop") {
                model.usePet(pet)
            }
            .buttonStyle(.borderedProminent)

            Button("Upgrade…") { upgrade(pet) }

            Spacer()

            Button("Uninstall", role: .destructive) { model.uninstallPet(pet) }
        }
        .padding(.top, 4)
    }

    // MARK: - Sprite cache

    private func preview(for pet: InstalledPet, track: String, size: CGFloat) -> some View {
        Group {
            if let sprite = sprites[pet.id] {
                AnimatedPetView(sprite: sprite, trackName: track)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size * 208 / 192)
    }

    /// Atlases are decoded once per pet and held, because decoding an 11 MB
    /// sheet on every list redraw would make the window unusable.
    private func loadSprites() {
        for pet in model.installedPets where sprites[pet.id] == nil {
            guard let loaded = try? PetPackageLoader().load(from: pet.root),
                  let atlas = loaded.atlas,
                  let frames = try? SpriteFrames(bitmap: atlas, profile: loaded.definition.profile)
            else { continue }
            sprites[pet.id] = frames
        }
    }

    private var currentPetID: String? { model.currentPetID }

    // MARK: - File pickers

    private func importFromDisk() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a pet package folder (one containing pet.json)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.installPet(from: url)
    }

    private func upgrade(_ pet: InstalledPet) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the new version of “\(pet.metadata.displayName)”"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.upgradePet(pet, from: url)
    }
}
