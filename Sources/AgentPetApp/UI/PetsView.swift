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
    /// One still per installed pet: the list is a wall of 40-point previews,
    /// and a decoded atlas each is what used to make this window's memory
    /// scale with the user's library.
    @State private var thumbnails: [String: NSImage] = [:]
    /// The selected pet's frames, so the detail pane can animate. Dropped when
    /// the selection moves on — one atlas at a time is the whole cost.
    @State private var detailFrames: SpriteFrames?
    @State private var warnings: [String: [String]] = [:]
    @State private var previewTrack = "idle"

    private let previewTracks = ["idle", "running", "waiting", "waving", "failed", "review"]

    var body: some View {
        HSplitView {
            installedList
                .frame(minWidth: 260, idealWidth: 300)
            detail
                .frame(minWidth: 340)
        }
        .task { loadThumbnails() }
        // The highlight lives in the model, so the page can be torn down and
        // rebuilt by a tab switch without forgetting which pet was on screen.
        // Nothing highlighted yet means the page is being opened for the first
        // time in this launch: start from the pet the desktop is showing.
        .onAppear {
            if model.highlightedPetID == nil { model.highlightedPetID = model.currentPetID }
            loadSelectedPet()
        }
        .onChange(of: model.highlightedPetID) { _, _ in loadSelectedPet() }
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
                    thumbnails.removeAll()
                    warnings.removeAll()
                    detailFrames = nil
                    loadThumbnails()
                    loadSelectedPet()
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
                List(selection: $model.highlightedPetID) {
                    ForEach(model.pets, id: \.id) { pet in
                        row(for: pet).tag(pet.id)
                    }
                    // Folders that look like pets and are not listed, with the
                    // reason `--diagnose` also prints. Last, and in its own
                    // section: they are not pets this window can offer.
                    if !model.skippedPets.isEmpty {
                        Section("Not listed") {
                            ForEach(model.skippedPets, id: \.root) { skip in
                                skippedRow(for: skip)
                            }
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(model.skippedPets.isEmpty ? "No pets found" : "No pets could be listed")
                .foregroundStyle(.secondary)
            if model.skippedPets.isEmpty {
                Text("Codex reads \(PetLibrary.petsDirectory.path).\nInstall one with:\n\nnpx codex-pets add <pet-id>")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            } else {
                // The empty list is where a missing pet is looked for, so the
                // reason has to be here and not only in `--diagnose`.
                Text("\(PetLibrary.petsDirectory.path) holds \(model.skippedPets.count) "
                     + "folder(s) that look like pets but cannot be played:")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                skippedList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var skippedList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.skippedPets, id: \.root) { skip in
                skippedRow(for: skip)
            }
        }
        .frame(maxWidth: 420)
    }

    private func row(for pet: PetLibrary.Entry) -> some View {
        HStack(spacing: 10) {
            thumbnail(for: pet, size: 40)
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

    /// A folder that carries a manifest and cannot be listed: the folder the
    /// user sees, and the sentence that says why it is not a pet here.
    private func skippedRow(for skip: PetLibraryScanner.Skipped) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .help("This folder cannot be listed")
            VStack(alignment: .leading, spacing: 2) {
                Text(skip.name)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text(skip.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([skip.root])
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal \(skip.name) in the Finder")
        }
        .padding(.vertical, 2)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let pet = model.highlightedPetID.flatMap(selectedPet) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        if let frames = detailFrames {
                            AnimatedPetView(sprite: frames, trackName: previewTrack)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 240)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))

                    // No title above the segments: in a pane this narrow the
                    // label wraps, and the track names already say what this
                    // is. The accessibility label keeps the meaning.
                    Picker("Preview animation", selection: $previewTrack) {
                        ForEach(previewTracks, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()

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

    // MARK: - Previews

    /// A still, drawn once and held. The row does not animate: at forty points
    /// a breathing pet is not readable anyway, and a timer per row is what made
    /// a list of twenty pets six hundred wake-ups a second.
    private func thumbnail(for pet: PetLibrary.Entry, size: CGFloat) -> some View {
        Group {
            if let image = thumbnails[pet.id] {
                Image(nsImage: image)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size * 208 / 192)
    }

    /// Decodes the atlases the list needs, one at a time, and keeps only the
    /// stills — the pixels are released as each row's image is drawn.
    private func loadThumbnails() {
        for pet in model.pets where thumbnails[pet.id] == nil {
            thumbnails[pet.id] = PetLibrary.thumbnail(of: pet, fitting: 40)
        }
    }

    /// The selected pet's frames, decoded on demand: the detail pane is the one
    /// place a real animation runs, so it is the one place an atlas is kept.
    private func loadSelectedPet() {
        guard let pet = model.highlightedPetID.flatMap(selectedPet) else {
            detailFrames = nil
            return
        }
        guard let loaded = try? PetLibrary.load(pet) else {
            detailFrames = nil
            warnings[pet.id] = ["could not be read"]
            return
        }
        warnings[pet.id] = (loaded.report.errors + loaded.report.warnings).map(\.message)
        detailFrames = loaded.atlas.flatMap {
            try? SpriteFrames(bitmap: $0, profile: loaded.definition.profile)
        }
    }

    /// Compatibility warnings only appear once the atlas is decoded, so they
    /// are collected when the selected pet is loaded rather than read off the
    /// discovery listing — a row that always said "None" would be worse than
    /// no row.
    private func warningSummary(for pet: PetLibrary.Entry) -> String {
        guard let messages = warnings[pet.id] else { return "Reading…" }
        return messages.isEmpty ? "None" : messages.joined(separator: " · ")
    }

    private var currentPetID: String? { model.currentPetID }
}
