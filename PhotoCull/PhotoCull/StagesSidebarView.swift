import SwiftUI
import SwiftData
import PhotoCatalog

/// The small left-aligned panel listing this photo's stages — Scene (if assigned), Single
/// (always present), then any Custom stages. Selecting a row only changes which stage's own
/// values `EditorSidebarView`/`ColorBalanceBarView` show ("blank slate" editing); the enabled
/// toggle controls whether a stage contributes to the composited render at all. See `Stage`'s doc
/// comment for the full model.
struct StagesSidebarView: View {
    let asset: PhotoAsset
    @Binding var selectedStage: Stage
    /// Cached active stage list (see `EditorView.activeStages`). This view is the one place that
    /// actually mutates stage *membership* (add/delete/enable-toggle), so it's the one place that
    /// needs to refresh this cache — everywhere else only edits a stage's own field values, which
    /// doesn't change which stages are active.
    @Binding var activeStages: [Stage]
    let coordinator: EditorRenderCoordinator
    @Environment(\.modelContext) private var modelContext

    @State private var renamingStage: Stage?
    @State private var renameText = ""

    var body: some View {
        List {
            Section("Stages") {
                if let sceneStage = asset.scene?.stage {
                    row(for: sceneStage, title: asset.scene.map { "Scene: \($0.name)" } ?? "Scene")
                }
                row(for: asset.singleStage, title: "Single")
                ForEach(asset.customStages) { stage in
                    row(for: stage, title: stage.name)
                        .contextMenu {
                            Button("Rename…") { beginRename(stage) }
                            Button("Delete", role: .destructive) { delete(stage) }
                        }
                }
            }
            Button {
                addCustomStage()
            } label: {
                Label("Add Custom Stage", systemImage: "plus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Color.sidebarBackground)
        .alert("Rename Stage", isPresented: Binding(
            get: { renamingStage != nil },
            set: { if !$0 { renamingStage = nil } }
        )) {
            TextField("Stage Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { renamingStage?.name = trimmed }
            }
        }
    }

    private func row(for stage: Stage, title: String) -> some View {
        HStack(spacing: 6) {
            Button {
                selectedStage = stage
            } label: {
                Text(title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("", isOn: Binding(
                get: { stage.isEnabled },
                set: { stage.isEnabled = $0; refreshAndRender() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .listRowBackground(selectedStage.id == stage.id ? Color.accentColor.opacity(0.2) : Color.clear)
    }

    /// Custom stages start with nothing set on any of the four kernel modules — a genuine blank
    /// slate, not a copy of whatever's currently selected.
    private func addCustomStage() {
        let nextIndex = (asset.customStages.map(\.sortIndex).max() ?? -1) + 1
        let stage = Stage(kind: .custom, name: "Custom \(nextIndex + 1)", asset: asset, sortIndex: nextIndex)
        modelContext.insert(stage)
        selectedStage = stage
        refreshAndRender()
    }

    private func beginRename(_ stage: Stage) {
        renamingStage = stage
        renameText = stage.name
    }

    private func delete(_ stage: Stage) {
        if selectedStage.id == stage.id {
            selectedStage = asset.singleStage
        }
        modelContext.delete(stage)
        refreshAndRender()
    }

    /// Structural changes (add/delete/enable-toggle) recompute `activeStages` from the
    /// relationships once, here — everywhere else reuses the cached array rather than walking
    /// `asset.scene`/`asset.stages` again on every render (see `EditorView.activeStages`).
    private func refreshAndRender() {
        activeStages = activeStageStack(for: asset)
        scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator)
    }
}
