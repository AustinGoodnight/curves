import SwiftUI
import SwiftData
import PhotoCatalog

/// Settings > Presets > "Manage Presets…" — the one place that sees *every* edit `Preset`, not just
/// the ones visible to the open photo's session the way the editor's `PresetBrowserView` does.
///
/// Left column: global presets (top level, then each `PresetFolder`), followed by one group per
/// session that has "Keep Within Session" presets — including sessions that no longer exist, since
/// a session preset only references its session by id (`Preset.sessionID`) and so outlives it.
/// Right column: the selected group's presets, with a context menu to rename, file into a folder,
/// promote a session preset to the global library ("Add to Global Presets"), set as the default
/// stage, or delete. Every mutation rewrites the on-disk backup (`PresetBackup.write(context:)`).
struct PresetManagerView: View {
    enum Location: Hashable {
        case topLevel
        case folder(UUID)
        case session(UUID)
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Preset.name) private var presets: [Preset]
    @Query(sort: \PresetFolder.name) private var folders: [PresetFolder]
    @Query private var sessions: [Session]

    @State private var location: Location? = .topLevel
    @State private var renamingPreset: Preset?
    @State private var renamingFolder: PresetFolder?
    @State private var isCreatingFolder = false
    @State private var nameText = ""

    /// One entry per distinct `sessionID` among session-scoped presets, named from the live
    /// `Session` when it still exists (so a renamed session shows its current name) and from the
    /// name captured at save time otherwise.
    private var sessionGroups: [(id: UUID, name: String, exists: Bool)] {
        let liveNames = Dictionary(sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var seen: [UUID: String] = [:]
        for preset in presets {
            guard let id = preset.sessionID, seen[id] == nil else { continue }
            seen[id] = liveNames[id] ?? preset.sessionName
        }
        return seen
            .map { (id: $0.key, name: $0.value, exists: liveNames[$0.key] != nil) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var presetsInLocation: [Preset] {
        switch location {
        case .topLevel, nil:
            return presets.filter { $0.sessionID == nil && $0.folder == nil }
        case .folder(let id):
            return presets.filter { $0.sessionID == nil && $0.folder?.id == id }
        case .session(let id):
            return presets.filter { $0.sessionID == id }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 210)
                Divider()
                presetList
                    .frame(maxWidth: .infinity)
            }
            Divider()
            HStack {
                Button {
                    nameText = "New Folder"
                    isCreatingFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 620, height: 440)
        .alert("New Folder", isPresented: $isCreatingFolder) {
            TextField("Folder Name", text: $nameText)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createFolder() }
        }
        .alert("Rename Folder", isPresented: Binding(
            get: { renamingFolder != nil },
            set: { if !$0 { renamingFolder = nil } }
        )) {
            TextField("Folder Name", text: $nameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let trimmed = trimmedName { renamingFolder?.name = trimmed; backUp() }
            }
        }
        .alert("Rename Preset", isPresented: Binding(
            get: { renamingPreset != nil },
            set: { if !$0 { renamingPreset = nil } }
        )) {
            TextField("Preset Name", text: $nameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                if let trimmed = trimmedName { renamingPreset?.name = trimmed; backUp() }
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $location) {
            Section("Global") {
                Label("All Presets", systemImage: "tray")
                    .badge(presets.filter { $0.sessionID == nil && $0.folder == nil }.count)
                    .tag(Location.topLevel)
                ForEach(folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .badge(folder.presets?.count ?? 0)
                        .tag(Location.folder(folder.id))
                        .contextMenu {
                            Button("Rename…") {
                                nameText = folder.name
                                renamingFolder = folder
                            }
                            Button("Delete Folder", role: .destructive) { delete(folder) }
                        }
                }
            }
            if !sessionGroups.isEmpty {
                Section("Sessions") {
                    ForEach(sessionGroups, id: \.id) { group in
                        Label {
                            Text(group.exists ? group.name : "\(group.name) (deleted)")
                        } icon: {
                            Image(systemName: group.exists ? "photo.on.rectangle" : "archivebox")
                        }
                        .tag(Location.session(group.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Preset list

    @ViewBuilder private var presetList: some View {
        let contents = presetsInLocation
        if contents.isEmpty {
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(contents) { preset in
                    HStack(spacing: 6) {
                        if preset.isDefault {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.secondary)
                                .imageScale(.small)
                                .help("Default stage for new imports")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                            Text(presetSummary(preset))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu {
                            menuItems(for: preset)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                    .contextMenu { menuItems(for: preset) }
                }
            }
        }
    }

    private var emptyMessage: String {
        switch location {
        case .folder: return "This folder is empty.\nMove presets here from their \u{2026} menu."
        case .session: return "No presets saved in this session."
        case .topLevel, nil: return "No global presets.\nSave one from the editor's Stages panel."
        }
    }

    @ViewBuilder private func menuItems(for preset: Preset) -> some View {
        Button("Rename…") {
            nameText = preset.name
            renamingPreset = preset
        }
        if preset.isSessionScoped {
            Menu("Add to Global Presets") {
                Button("Top Level") { makeGlobal(preset, folder: nil) }
                if !folders.isEmpty { Divider() }
                ForEach(folders) { folder in
                    Button(folder.name) { makeGlobal(preset, folder: folder) }
                }
            }
        } else {
            Menu("Move to Folder") {
                Button("Top Level") { move(preset, to: nil) }
                    .disabled(preset.folder == nil)
                if !folders.isEmpty { Divider() }
                ForEach(folders) { folder in
                    Button(folder.name) { move(preset, to: folder) }
                        .disabled(preset.folder?.id == folder.id)
                }
            }
        }
        Button(preset.isDefault ? "Remove as Default Stage" : "Set as Default Stage") {
            toggleDefault(preset)
        }
        Divider()
        Button("Delete", role: .destructive) {
            modelContext.delete(preset)
            backUp()
        }
    }

    // MARK: Actions

    private var trimmedName: String? {
        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func createFolder() {
        guard let name = trimmedName else { return }
        let folder = PresetFolder(name: name)
        modelContext.insert(folder)
        backUp()
        location = .folder(folder.id)
    }

    /// Presets inside go back to the top level (`PresetFolder.presets`' `.nullify` rule) — never
    /// deleted along with the folder.
    private func delete(_ folder: PresetFolder) {
        if location == .folder(folder.id) { location = .topLevel }
        modelContext.delete(folder)
        backUp()
    }

    private func move(_ preset: Preset, to folder: PresetFolder?) {
        preset.folder = folder
        backUp()
    }

    /// Promotes a "Keep Within Session" preset into the global library: it's then listed in the
    /// editor for every session, and filed like any other global preset.
    private func makeGlobal(_ preset: Preset, folder: PresetFolder?) {
        preset.sessionID = nil
        preset.sessionName = ""
        preset.folder = folder
        backUp()
        if presetsInLocation.isEmpty {
            location = folder.map { .folder($0.id) } ?? .topLevel
        }
    }

    /// Same single-default invariant as `PresetBrowserView.toggleDefault(_:)`.
    private func toggleDefault(_ preset: Preset) {
        let turningOn = !preset.isDefault
        for other in presets where other.isDefault {
            other.isDefault = false
        }
        preset.isDefault = turningOn
        backUp()
    }

    private func backUp() {
        PresetBackup.write(context: modelContext)
    }
}
