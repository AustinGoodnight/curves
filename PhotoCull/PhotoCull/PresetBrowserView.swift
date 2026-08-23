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

    /// At most one preset is ever the default — clears the flag on every other one first, matching
    /// `StagesSidebarView.saveAsDefaultStage(_:)`'s own invariant.
    private func toggleDefault(_ preset: Preset) {
        let turningOn = !preset.isDefault
        for other in presets where other.isDefault {
            other.isDefault = false
        }
        preset.isDefault = turningOn
    }
}
