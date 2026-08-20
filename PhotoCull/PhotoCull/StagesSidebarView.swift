import SwiftUI
import SwiftData
import PhotoCatalog

/// The small left-aligned panel listing this photo's stages — Scene (if assigned), Single
/// (always present), then any Custom stages. Selecting a row only changes which stage's own
/// values `EditorSidebarView`/`ColorBalanceBarView` show ("blank slate" editing); the enabled
/// toggle controls whether a stage contributes to the composited render at all. See `Stage`'s doc
/// comment for the full model. When `asset` is stacked, "Single" and every custom stage shown here
/// are shared with the rest of the stack (`PhotoStack.stages`) — editing them here edits every
/// stacked photo identically; there's no separate "this photo only" layer while stacked.
struct StagesSidebarView: View {
    let asset: PhotoAsset
    @Binding var selectedStage: Stage
    /// Cached active stage list (see `EditorView.activeStages`). This view is the one place that
    /// actually mutates stage *membership* (add/delete/enable-toggle), so it's the one place that
    /// needs to refresh this cache — everywhere else only edits a stage's own field values, which
    /// doesn't change which stages are active.
    @Binding var activeStages: [Stage]
    let coordinator: EditorRenderCoordinator
    /// Lets a row in the "Stack" section below switch the editor to that photo — see
    /// `EditorView.onSelectAsset`'s doc comment.
    var onSelectAsset: (PhotoAsset) -> Void
    @Environment(\.modelContext) private var modelContext

    @State private var renamingStage: Stage?
    @State private var renameText = ""

    /// Every photo in this asset's stack, `asset` itself included, in capture order — so the
    /// section shows the full stack with the currently-open one marked, not just "everything else".
    /// Empty (hiding the whole "Stack" section) when this photo isn't stacked with anything, or its
    /// stack has no other members.
    private var stackedPhotos: [PhotoAsset] {
        guard let stack = asset.stack, (stack.photos ?? []).count > 1 else { return [] }
        return (stack.photos ?? []).sorted { ($0.captureDate ?? $0.importDate) < ($1.captureDate ?? $1.importDate) }
    }

    var body: some View {
        List {
            Section("Stages") {
                if let sceneStage = asset.scene?.stage {
                    row(for: sceneStage, title: asset.scene.map { "Scene: \($0.name)" } ?? "Scene")
                }
                // When `asset` is stacked, `singleStage`/`customStages` are already the *shared*
                // ones from `asset.stack` (see `PhotoAsset.singleStage`'s doc comment) — so this
                // row and the `ForEach` below need no special-casing to show/edit them.
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
            if !stackedPhotos.isEmpty {
                Section("Stack") {
                    ForEach(stackedPhotos) { photo in
                        let isCurrent = photo.id == asset.id
                        HStack(spacing: 8) {
                            CompactPhotoThumbnail(asset: photo, isCurrent: isCurrent, size: 36)
                            Text(photo.fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.primary)
                            if isCurrent {
                                Spacer()
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { if !isCurrent { onSelectAsset(photo) } }
                        .listRowBackground(isCurrent ? Color.accentColor.opacity(0.2) : Color.clear)
                    }
                }
            }
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
    /// slate, not a copy of whatever's currently selected. Owned by `asset.stack` instead of
    /// `asset` itself when stacked, so it's immediately shared with every other member — same
    /// routing as `PhotoAsset.customStages` reads, just on the write side.
    private func addCustomStage() {
        let nextIndex = (asset.customStages.map(\.sortIndex).max() ?? -1) + 1
        let stage: Stage
        if let stack = asset.stack {
            stage = Stage(kind: .custom, name: "Custom \(nextIndex + 1)", stack: stack, sortIndex: nextIndex)
        } else {
            stage = Stage(kind: .custom, name: "Custom \(nextIndex + 1)", asset: asset, sortIndex: nextIndex)
        }
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
