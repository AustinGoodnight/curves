import SwiftUI
import SwiftData
import PhotoCatalog

/// The reusable-preset library, listed below the Stages edit tree in `StagesSidebarView`. A genuine
/// separate `View` type (not inline in `StagesSidebarView.body`) — same isolation reasoning as
/// `FilmSimulationPicker`: this is the one place with its own `@Query`, and SwiftData's broad
/// change-tracking means saving/renaming/deleting *any* `Preset` is enough to re-invoke a `body`
/// that reads the query, so scoping that to this small section keeps it from also re-diffing the
/// stage list, Versions, and History sections above it.
///
/// Shows every global preset plus any "Keep Within Session" presets saved for the open photo's
/// session (`sessionID`) — presets scoped to other sessions are filtered out in the `@Query`
/// predicate itself. Global presets are grouped by `PresetFolder`; folders are created and
/// presets filed into them from Settings > Presets (`PresetManagerView`). Grouping here is done in
/// `body` directly: it's a pass over the (small, user-curated) preset list, never over
/// `allAssets`, so it's outside what this project's CLAUDE.md performance rules are about.
///
/// Applying a preset (tapping its row) always adds a new **stage** to the currently-open photo —
/// see `Preset`'s doc comment for why it's never a scene.
struct PresetBrowserView: View {
    var onApply: (Preset) -> Void

    @Query private var presets: [Preset]
    @Query(sort: \PresetFolder.name) private var folders: [PresetFolder]
    @Environment(\.modelContext) private var modelContext

    @State private var renamingPreset: Preset?
    @State private var renameText = ""

    init(sessionID: UUID?, onApply: @escaping (Preset) -> Void) {
        self.onApply = onApply
        let sessionID = sessionID
        _presets = Query(
            filter: #Predicate<Preset> { $0.sessionID == nil || $0.sessionID == sessionID },
            sort: \Preset.name
        )
    }

    var body: some View {
        Group {
            if presets.isEmpty {
                Text("No Presets Saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let sessionPresets = presets.filter(\.isSessionScoped)
                let globalPresets = presets.filter { !$0.isSessionScoped }
                if !sessionPresets.isEmpty {
                    DisclosureGroup {
                        ForEach(sessionPresets) { row(for: $0) }
                    } label: {
                        Label("This Session", systemImage: "folder.badge.person.crop")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(folders) { folder in
                    let contents = globalPresets.filter { $0.folder?.id == folder.id }
                    if !contents.isEmpty {
                        DisclosureGroup {
                            ForEach(contents) { row(for: $0) }
                        } label: {
                            Label(folder.name, systemImage: "folder")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                ForEach(globalPresets.filter { $0.folder == nil }) { row(for: $0) }
            }
        }
        .alert("Rename Preset", isPresented: Binding(
            get: { renamingPreset != nil },
            set: { if !$0 { renamingPreset = nil } }
        )) {
            TextField("Preset Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    renamingPreset?.name = trimmed
                    PresetBackup.write(context: modelContext)
                }
            }
        }
    }

    private func row(for preset: Preset) -> some View {
        Button {
            onApply(preset)
        } label: {
            HStack(spacing: 4) {
                if preset.isDefault {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.secondary)
                        .imageScale(.small)
                }
                Text(preset.name)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(presetSummary(preset))
        .contextMenu {
            // Every new photo's `.single` stage starts pre-populated from whichever
            // preset has this flag — see `StageFieldSnapshot.applyDefaultIfAvailable(to:
            // context:)`. Toggling it here (rather than only via `StagesSidebarView`'s
            // "Save as Default Stage") is what lets the user pick an *existing* preset
            // as the default, or turn the current one off without replacing it.
            Button(preset.isDefault ? "Remove as Default Stage" : "Set as Default Stage") {
                toggleDefault(preset)
            }
            Button("Rename…") { beginRename(preset) }
            Button("Delete", role: .destructive) {
                modelContext.delete(preset)
                PresetBackup.write(context: modelContext)
            }
        }
    }

    private func beginRename(_ preset: Preset) {
        renamingPreset = preset
        renameText = preset.name
    }

    /// At most one preset is ever the default — clears the flag on every other one first, matching
    /// `StagesSidebarView.saveAsDefaultStage(_:)`'s own invariant. Fetches rather than walking
    /// `presets`, since the current default may be scoped to a different session and so filtered
    /// out of this view's query.
    private func toggleDefault(_ preset: Preset) {
        let turningOn = !preset.isDefault
        let defaults = FetchDescriptor<Preset>(predicate: #Predicate { $0.isDefault })
        for other in (try? modelContext.fetch(defaults)) ?? [] {
            other.isDefault = false
        }
        preset.isDefault = turningOn
        PresetBackup.write(context: modelContext)
    }
}

/// "Includes: Exposure, White Balance" — the tooltip/secondary line describing which asset-level
/// fields a preset carries on top of its stage values. Shared with `PresetManagerView`.
func presetSummary(_ preset: Preset) -> String {
    var parts: [String] = []
    if preset.includesExposure { parts.append("Exposure") }
    if preset.includesWhiteBalance { parts.append("White Balance") }
    return parts.isEmpty ? "Stage adjustments only" : "Stage adjustments + " + parts.joined(separator: ", ")
}
