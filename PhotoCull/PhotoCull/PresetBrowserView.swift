import SwiftUI
import SwiftData
import PhotoCatalog

/// The reusable-preset library, listed below the Stages edit tree in `StagesSidebarView`. A genuine
/// separate `View` type (not inline in `StagesSidebarView.body`) — same isolation reasoning as
/// `LUT3DPresetMenu`: this is the one place with its own `@Query`, and SwiftData's broad
/// change-tracking means saving/renaming/deleting *any* `Preset` is enough to re-invoke a `body`
/// that reads the query, so scoping that to this small section keeps it from also re-diffing the
/// stage list, Versions, and History sections above it.
///
/// Applying a preset (tapping its row) always adds a new **stage** to the currently-open photo —
/// see `Preset`'s doc comment for why it's never a scene.
struct PresetBrowserView: View {
    var onApply: (Preset) -> Void

    @Query(sort: \Preset.name) private var presets: [Preset]
    @Environment(\.modelContext) private var modelContext

    @State private var renamingPreset: Preset?
    @State private var renameText = ""

    var body: some View {
        Group {
            if presets.isEmpty {
                Text("No Presets Saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(presets) { preset in
                    Button {
                        onApply(preset)
                    } label: {
                        Text(preset.name)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Rename…") { beginRename(preset) }
                        Button("Delete", role: .destructive) { modelContext.delete(preset) }
                    }
                }
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
                if !trimmed.isEmpty { renamingPreset?.name = trimmed }
            }
        }
    }

    private func beginRename(_ preset: Preset) {
        renamingPreset = preset
        renameText = preset.name
    }
}
