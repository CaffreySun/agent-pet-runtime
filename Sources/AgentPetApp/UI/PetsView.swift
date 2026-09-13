import AgentPetCore
import AppKit
import SwiftUI

/// Pet Manager: what Codex has installed, and how to install more.
///
/// Read-only by design. Pets live in Codex's own pets directory and are added,
/// updated, and removed with Codex's own tooling; a second manager here would
/// be a second source of truth, and the two would drift.
struct PetsView: View {

    @ObservedObject var model: AgentPetModel
    @State private var sprites: [String: SpriteFrames] = [:]
    @State private var warnings: [String: [String]] = [:]
    @State private var selection: String?
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
                Text("Pets")
                    .font(.headline)
                Spacer()
                // Pets are installed from a terminal, so the directory can
                // change while this window is open.
                Button {
                    model.refreshPets()
                    sprites.removeAll()
                    warnings.removeAll()
                    loadSprites()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Read \(PetLibrary.petsDirectory.path) again")
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([PetLibrary.petsDirectory])
                } label: {
                    Image(systemName: "folder")
                }
                .help("Reveal \(PetLibrary.petsDirectory.path) in the Finder")
            }
            .padding(10)

            Divider()

            if model.pets.isEmpty {
                emptyState
            } else {
                List(model.pets, id: \.id, selection: $selection) { pet in
                    row(for: pet).tag(pet.id)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No pets found")
                .foregroundStyle(.secondary)
            Text("Codex reads \(PetLibrary.petsDirectory.path).\nInstall one with:\n\nnpx codex-pets add <pet-id>")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func row(for pet: PetLibrary.Entry) -> some View {
        HStack(spacing: 10) {
            preview(for: pet, track: "idle", size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(pet.name).fontWeight(.medium)
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

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let pet = selection.flatMap(selectedPet) {
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
                        Text(pet.name).font(.title2)
                        Text(pet.definition.description)
                            .foregroundStyle(.secondary)
                    }

                    infoGrid(for: pet)
                    actions(for: pet)
                    managementNotes(for: pet)
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

    private func selectedPet(_ id: String) -> PetLibrary.Entry? {
        model.pets.first { $0.id == id }
    }

    private func infoGrid(for pet: PetLibrary.Entry) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            row("ID", pet.id)
            row("Profile", pet.definition.profile.rawValue)
            row("Folder", pet.root.path)
            row("Warnings", warningSummary(for: pet))
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

    private func actions(for pet: PetLibrary.Entry) -> some View {
        HStack {
            Button("Use on Desktop") {
                model.usePet(pet)
            }
            .buttonStyle(.borderedProminent)

            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([pet.root])
            }

            Spacer()
        }
        .padding(.top, 4)
    }

    /// What this window deliberately does not do, and where to do it instead.
    private func managementNotes(for pet: PetLibrary.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text("Adding, updating, and removing pets happens in Codex, not here.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("""
                Install or update — re-running it is safe, and that is what updating means:
                  npx codex-pets add \(pet.id)

                Remove — a pet is a folder; deleting it is the whole operation:
                  rm -rf "\(pet.root.path)"

                Any folder in \(PetLibrary.petsDirectory.path) with a pet.json and a \
                spritesheet works, however it got there. Codex picks the pet in its own \
                terminal picker.
                """)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: - Sprite cache

    private func preview(for pet: PetLibrary.Entry, track: String, size: CGFloat) -> some View {
        Group {
            if let sprite = sprites[pet.id] {
                AnimatedPetView(sprite: sprite, trackName: track)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size * 208 / 192)
    }

    /// Compatibility warnings only appear once the atlas is decoded, so they
    /// are collected here rather than read off the discovery listing — a row
    /// that always said "None" would be worse than no row.
    private func warningSummary(for pet: PetLibrary.Entry) -> String {
        guard let messages = warnings[pet.id] else { return "Reading…" }
        return messages.isEmpty ? "None" : messages.joined(separator: " · ")
    }

    /// Atlases are decoded once per pet and held, because decoding an 11 MB
    /// sheet on every list redraw would make the window unusable.
    private func loadSprites() {
        for pet in model.pets where sprites[pet.id] == nil {
            do {
                let loaded = try PetPackageLoader().load(from: pet.root)
                guard let atlas = loaded.atlas else { continue }
                sprites[pet.id] = try SpriteFrames(
                    bitmap: atlas, profile: loaded.definition.profile
                )
                warnings[pet.id] = loaded.report.warnings.map(\.message)
            } catch {
                warnings[pet.id] = ["\(error)"]
            }
        }
    }

    private var currentPetID: String? { model.currentPetID }
}
