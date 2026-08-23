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
    /// Only used by the "Versions" section's restore action — a version restore is a value-level
    /// change (base params + Single stage fields), so it's naturally undoable through the same
    /// mechanism as any slider edit. Every other mutation in this view (add/delete/rename/
    /// enable-toggle a stage) is structural and deliberately isn't threaded through `history` —
    /// see `EditHistory`'s doc comment.
    let history: EditHistory
    /// Lets a row in the "Stack" section below switch the editor to that photo — see
    /// `EditorView.onSelectAsset`'s doc comment.
    var onSelectAsset: (PhotoAsset) -> Void
    /// Enters the assisted-mask editor (`EditorView.maskEditingStage`) for the given stage — called
    /// both right after creating a new `.assistedMask` stage and from an existing one's "Refine
    /// Mask…" context menu item.
    var onEditMask: (Stage) -> Void
    @Environment(\.modelContext) private var modelContext

    @State private var renamingStage: Stage?
    @State private var renameText = ""

    @State private var isSavingVersion = false
    @State private var newVersionName = ""
    @State private var renamingVersion: AssetVersion?
    @State private var renameVersionText = ""
    @State private var branchingFromVersion: AssetVersion?
    @State private var newBranchName = ""
    /// Set by `createBranch()`, consumed by the *next* `saveVersion()` — a branch, like in git, is
    /// just a name; it doesn't create a checkpoint of its own until something is actually saved
    /// on it. `nil` means "inherit whatever branch `currentVersionID` is on" (the normal case).
    @State private var pendingBranchName: String?

    /// This asset's saved checkpoints, newest first — see `AssetVersion`'s doc comment. Reading
    /// `asset.versions` directly (no separate `@Query`) matches how `asset.customStages`/
    /// `asset.scene?.stage` are already read straight from `body` in this same file: a bounded,
    /// per-asset relationship read, not a library-wide query, so it doesn't carry the
    /// `@Query`-on-every-render cost this project's `CLAUDE.md` warns about elsewhere.
    private var sortedVersions: [AssetVersion] {
        (asset.versions ?? []).sorted { $0.createdDate > $1.createdDate }
    }

    /// Whichever version is checked out right now (`asset.currentVersionID`) — `nil` before the
    /// first version has ever been saved, or after that version was deleted. The "New Branch…"
    /// button's default source.
    private var currentVersion: AssetVersion? {
        sortedVersions.first { $0.id == asset.currentVersionID }
    }

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
                            if stage.kind == .assistedMask {
                                Button("Refine Mask…") { onEditMask(stage) }
                            }
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
            Button {
                addAssistedMaskStage()
            } label: {
                Label("Add Assisted Mask Stage", systemImage: "wand.and.stars")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Section("Info") {
                VStack(alignment: .leading, spacing: 6) {
                    if !asset.cameraModel.isEmpty {
                        infoRow("Camera", asset.cameraModel)
                    }
                    if !asset.lensModel.isEmpty {
                        infoRow("Lens", asset.lensModel)
                    }
                    if !exposureSummary.isEmpty {
                        infoRow("Exposure", exposureSummary)
                    }
                }
                .listRowSeparator(.hidden)
            }
            Section("Versions") {
                if !sortedVersions.isEmpty {
                    VersionTreeView(
                        versions: sortedVersions,
                        currentVersionID: asset.currentVersionID,
                        onSelect: { restore($0) },
                        onNewBranch: { beginNewBranch($0) },
                        onRename: { beginRenameVersion($0) },
                        onDelete: { deleteVersion($0) }
                    )
                    .listRowSeparator(.hidden)
                }
                Button {
                    newVersionName = "Version \(sortedVersions.count + 1)"
                    isSavingVersion = true
                } label: {
                    Label("Save Version…", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // Shortcut for "branch from wherever I am right now" — same action as a version
                // row's "New Branch from Here…", just defaulted to the checked-out version instead
                // of requiring a right-click on a specific row. Disabled until there's at least one
                // version to branch from, same as `git branch` needing at least one commit to exist.
                Button {
                    if let currentVersion { beginNewBranch(currentVersion) }
                } label: {
                    Label("New Branch…", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(currentVersion == nil)
            }
            Section("History") {
                EditHistoryListView(history: history)
                    .listRowSeparator(.hidden)
            }
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
        .alert("Save Version", isPresented: $isSavingVersion) {
            TextField("Version Name", text: $newVersionName)
            Button("Cancel", role: .cancel) {}
            Button("Save") { saveVersion() }
        }
        .alert("Rename Version", isPresented: Binding(
            get: { renamingVersion != nil },
            set: { if !$0 { renamingVersion = nil } }
        )) {
            TextField("Version Name", text: $renameVersionText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let trimmed = renameVersionText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { renamingVersion?.name = trimmed }
            }
        }
        .alert("New Branch", isPresented: Binding(
            get: { branchingFromVersion != nil },
            set: { if !$0 { branchingFromVersion = nil } }
        )) {
            TextField("Branch Name", text: $newBranchName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { createBranch() }
        } message: {
            Text("Checks out \u{201C}\(branchingFromVersion?.name ?? "")\u{201D} — the next version you save will start this new branch.")
        }
    }

    /// `"f/2.8  1/250s  ISO 400  50mm"` — whichever of the four EXIF readouts the file actually
    /// had, space-joined; empty when none did (a file with no EXIF at all, or one imported before
    /// this field existed).
    private var exposureSummary: String {
        [asset.apertureDisplay, asset.shutterSpeedDisplay, asset.isoDisplay, asset.focalLengthDisplay]
            .filter { !$0.isEmpty }
            .joined(separator: "  ")
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }

    private func row(for stage: Stage, title: String) -> some View {
        HStack(spacing: 6) {
            Button {
                selectedStage = stage
            } label: {
                HStack(spacing: 4) {
                    if stage.kind == .assistedMask {
                        Image(systemName: "wand.and.stars")
                            .foregroundStyle(.secondary)
                            .imageScale(.small)
                    }
                    Text(title)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
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

    /// Encodes the asset's current base params + Single stage into a new `AssetVersion`, parented
    /// to whatever's currently checked out — see `AssetVersion`'s doc comment for how that parent
    /// pointer alone is what makes this "git-like". `pendingBranchName` (set by `createBranch()`)
    /// wins over inheriting the parent's branch, and is consumed here whether or not the save goes
    /// through, so a cancelled/empty save doesn't leave a stale pending branch behind. Silently
    /// does nothing if encoding somehow fails (every field here is a plain
    /// Double?/Bool/Data?/[Double]?/String?, so in practice this can't actually fail).
    private func saveVersion() {
        let branchName = pendingBranchName
        pendingBranchName = nil
        let trimmed = newVersionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Version \(sortedVersions.count + 1)" : trimmed
        guard let data = try? JSONEncoder().encode(AssetVersionSnapshot(asset: asset)) else { return }
        let parent = currentVersion
        let version = AssetVersion(
            name: name, branchName: branchName ?? parent?.branchName ?? "main",
            asset: asset, parent: parent, snapshotData: data
        )
        modelContext.insert(version)
        asset.currentVersionID = version.id
    }

    /// Decodes `version` and writes it onto `asset`/`asset.singleStage`, moves "current" to it
    /// (git's checkout), then schedules a render through `history` — restoring doesn't touch
    /// `activeStages` membership, so it's a plain value-level change like any slider edit.
    private func restore(_ version: AssetVersion) {
        guard let snapshot = try? JSONDecoder().decode(AssetVersionSnapshot.self, from: version.snapshotData) else { return }
        snapshot.apply(to: asset)
        asset.currentVersionID = version.id
        scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
    }

    private func beginRenameVersion(_ version: AssetVersion) {
        renamingVersion = version
        renameVersionText = version.name
    }

    private func beginNewBranch(_ version: AssetVersion) {
        branchingFromVersion = version
        newBranchName = ""
    }

    /// Checks out `branchingFromVersion` (so the branch starts from its exact state) and remembers
    /// the new name for `saveVersion()` to use next — matching `git branch <name>` followed by a
    /// commit: creating the branch alone adds nothing to the graph until something's saved on it.
    private func createBranch() {
        guard let source = branchingFromVersion else { return }
        let trimmed = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        restore(source)
        pendingBranchName = trimmed
    }

    private func deleteVersion(_ version: AssetVersion) {
        if asset.currentVersionID == version.id { asset.currentVersionID = nil }
        modelContext.delete(version)
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

    /// Same blank-slate/ownership rules as `addCustomStage()`, but immediately hands the new stage
    /// to `onEditMask` so the assisted-mask editor opens right away — an `.assistedMask` stage with
    /// no mask yet isn't a useful state to leave the user in.
    private func addAssistedMaskStage() {
        let nextIndex = (asset.customStages.map(\.sortIndex).max() ?? -1) + 1
        let stage: Stage
        if let stack = asset.stack {
            stage = Stage(kind: .assistedMask, name: "Assisted Mask \(nextIndex + 1)", stack: stack, sortIndex: nextIndex)
        } else {
            stage = Stage(kind: .assistedMask, name: "Assisted Mask \(nextIndex + 1)", asset: asset, sortIndex: nextIndex)
        }
        modelContext.insert(stage)
        selectedStage = stage
        refreshAndRender()
        onEditMask(stage)
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
