import SwiftUI
import SwiftData
import AppKit
import PhotoCatalog

/// ⚠️ PERFORMANCE TRAP — see `CLAUDE.md` at the repo root for the full writeup. Short version:
/// 1. Never read an expensive computed property (anything that filters/scans `allAssets`/
///    `scenes`/`sessions`) directly inside `body`/`toolbarContent`.
/// 2. Never put frequently-mutated state (anything that changes on every click, like selection)
///    directly on `ContentView`'s own `@State` — that's why it all lives on `DetailStore`
///    (`DetailPaneView.swift`) instead, an `@Observable` object owned here but never read
///    directly by *this* view's own `body` (only passed down), so Swift's Observation framework
///    scopes click-driven invalidation to whichever small view actually reads each property.
/// 3. **Reading `@Query var allAssets` — even just to pass it as a value parameter to a child
///    view, never touching its contents — costs real time (~250ms measured on a 1708-asset
///    library) on this SDK, independent of what's done with the value.** This is *not* about
///    SwiftUI diffing, `.equatable()`, or Observation bookkeeping — a bisection down to a single
///    inert, unused `@State var` proved those innocent. The actual mechanism: every editor slider
///    tick writes to a `PhotoAsset`/`Stage` field, which makes `@Query` consider `allAssets`
///    "possibly changed" and forces `ContentView.body` to re-run — and if *anything* in that body
///    reads `allAssets`'s value unconditionally (not gated behind `editingAsset == nil`, and not
///    deferred into a closure/action-handler that only runs on user interaction), that read alone
///    pays the ~250ms cost, every tick, regardless of `.equatable()`/gating anywhere else. Two
///    separate call sites did this and both had to be fixed: `GridPane(allAssets: allAssets, ...)`
///    being constructed unconditionally (gating moved to wrap its *construction*, not just inside
///    `GridPane.body`), and `EditButton` taking `allAssets` as a stored value parameter instead of
///    a closure that captures it lazily. **Rule going forward: never pass `allAssets`/`scenes`/
///    `sessions` as a plain value parameter to anything constructed on every `body` pass — gate the
///    construction itself behind whatever makes it actually necessary, or hand over a closure that
///    reads the property lazily, at the point it's actually used.**
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PhotoAsset.captureDate, order: .reverse) private var allAssets: [PhotoAsset]
    @Query(sort: \PhotoScene.name) private var scenes: [PhotoScene]
    @Query(sort: \Session.createdDate, order: .reverse) private var sessions: [Session]

    @State private var selectedScene: PhotoScene?
    @State private var selectedSession: Session?
    @State private var importStatus: String?
    @State private var isShowingSessionPicker = false
    @State private var pendingImportFiles: [URL] = []
    @State private var newSessionName = ""

    @State private var detailStore = DetailStore()
    /// Collapsed to `.detailOnly` while editing — see `.onChange(of: detailStore.editingAsset)`
    /// below. The Library/Sessions/Scenes list has nothing to do with editing a single photo, and
    /// hiding it gives the editor's own `StagesSidebarView`/image/`EditorSidebarView` the full
    /// window width. A manual toggle while editing (the sidebar button, ⌃⌘S) can still bring it
    /// back — this only sets the *default*, it doesn't lock the column closed.
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            SidebarView(
                sessions: sessions,
                scenes: scenes,
                selectedSession: $selectedSession,
                selectedScene: $selectedScene,
                onNewScene: { session in
                    detailStore.addSelectionToNewScene = false
                    detailStore.newSceneName = ""
                    detailStore.newSceneSession = session
                    detailStore.isShowingNewSceneAlert = true
                },
                onDeleteScene: deleteScene
            )
            .equatable()
        } detail: {
            // Grid and editor are swapped in place here rather than the editor being pushed via
            // `navigationDestination` (as it used to be) — that let each screen have its own
            // toolbar, which is exactly what made the Sessions/Edit toggle *not* persistent: it
            // simply didn't exist on the editor's separate toolbar. One shared `toolbarContent`
            // below, attached once, is what makes it persistent across both. `editingAsset == nil`
            // still gates `GridPane`'s *construction* here, not just its body — see this file's
            // header comment (trap #3) for why that distinction matters. `.id(editingAsset.id)` on
            // the editor branch forces a fresh `EditorView` (fresh `@State` coordinator/stage) every
            // time `editingAsset` changes — including a direct switch from one photo to another via
            // `SessionFilmstripView`/`StagesSidebarView`'s "Stack" section, which never passes
            // through `nil`. Without this, the `if`/`else` branch alone gives SwiftUI no reason to
            // recreate the view for a same-branch identity change, and the coordinator/stage state
            // from the *previous* photo would leak into the new one.
            Group {
                if let editingAsset = detailStore.editingAsset {
                    EditorView(asset: editingAsset, onSelectAsset: openEditor)
                        .id(editingAsset.id)
                } else {
                    GridPane(
                        allAssets: allAssets, selectedScene: selectedScene, selectedSession: selectedSession,
                        store: detailStore, onGroupStack: groupSelectedIntoStack, onUnstack: unstackSelected,
                        onOpenEditor: openEditor
                    )
                    .equatable()
                    .id(detailStore.refreshTrigger)
                }
            }
            .navigationTitle(detailStore.editingAsset?.fileName ?? selectedScene?.name ?? selectedSession?.name ?? "PhotoCull")
            .toolbar { toolbarContent }
            .toolbarBackground(Color.sidebarBackground, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        .background {
            Button("Add Selected to Scene") {
                guard detailStore.commonSessionForSelection != nil else { return }
                detailStore.quickSceneName = ""
                detailStore.isShowingScenePicker = true
            }
            .keyboardShortcut("s", modifiers: .command)
            .hidden()
        }
        .alert("Import", isPresented: Binding(
            get: { importStatus != nil },
            set: { if !$0 { importStatus = nil } }
        ), presenting: importStatus) { _ in
            Button("OK") { importStatus = nil }
        } message: { status in
            Text(status)
        }
        .alert("New Scene", isPresented: $detailStore.isShowingNewSceneAlert) {
            TextField("Scene Name", text: $detailStore.newSceneName)
            Button("Cancel", role: .cancel) { detailStore.newSceneName = ""; detailStore.newSceneSession = nil }
            Button("Create") { createScene(named: detailStore.newSceneName, addSelection: detailStore.addSelectionToNewScene) }
        } message: {
            Text("Enter a name for the new scene.")
        }
        .sheet(isPresented: $isShowingSessionPicker) {
            SessionPickerSheet(
                sessions: sessions,
                newSessionName: $newSessionName,
                onPick: { session in
                    isShowingSessionPicker = false
                    performImport(files: pendingImportFiles, session: session)
                    pendingImportFiles = []
                },
                onCreate: { name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let session = Session(name: trimmed)
                    modelContext.insert(session)
                    isShowingSessionPicker = false
                    performImport(files: pendingImportFiles, session: session)
                    pendingImportFiles = []
                    newSessionName = ""
                },
                onCancel: {
                    isShowingSessionPicker = false
                    pendingImportFiles = []
                }
            )
        }
        .sheet(isPresented: $detailStore.isShowingScenePicker) {
            ScenePickerSheet(
                scenes: detailStore.scenesInCommonSession,
                newSceneName: $detailStore.quickSceneName,
                onPick: { scene in
                    addSelected(to: scene)
                    detailStore.isShowingScenePicker = false
                },
                onCreate: { name in quickCreateAndAssignScene(named: name) },
                onCancel: { detailStore.isShowingScenePicker = false }
            )
        }
        .onChange(of: detailStore.selection) { _, _ in detailStore.refreshSelectionDerivedState(allAssets: allAssets, scenes: scenes) }
        .onChange(of: detailStore.editingAsset) { _, newValue in
            detailStore.refreshSelectionDerivedState(allAssets: allAssets, scenes: scenes)
            sidebarVisibility = newValue == nil ? .all : .detailOnly
        }
        .onChange(of: selectedScene) { _, _ in refreshFilteredAssets() }
        .onChange(of: selectedSession) { _, _ in refreshFilteredAssets() }
        .onChange(of: detailStore.ratingFilter) { _, _ in refreshFilteredAssets() }
        .onChange(of: detailStore.flagFilter) { _, _ in refreshFilteredAssets() }
        .onChange(of: detailStore.sortOption) { _, _ in refreshFilteredAssets() }
        .onChange(of: detailStore.gridMode) { _, newMode in
            switch newMode {
            case .edit:
                guard detailStore.editingAsset == nil, detailStore.selection.count == 1, let id = detailStore.selection.first,
                      let asset = allAssets.first(where: { $0.id == id }) else { return }
                openEditor(for: asset)
            case .sessions:
                guard detailStore.editingAsset != nil else { return }
                closeEditor()
            }
        }
        .task {
            backfillMissingSessions()
            cleanupLegacyStackKindStages()
            backfillMissingStackStages()
            refreshFilteredAssets()
        }
    }

    private func refreshFilteredAssets() {
        detailStore.refreshFilteredAssets(allAssets: allAssets, selectedScene: selectedScene, selectedSession: selectedSession)
    }

    private func openEditor(for asset: PhotoAsset) {
        detailStore.editingAsset = asset
    }

    private func closeEditor() {
        try? modelContext.save()
        detailStore.editingAsset = nil
    }

    private func backfillMissingSessions() {
        let orphaned = allAssets.filter { $0.session == nil }
        guard !orphaned.isEmpty else { return }
        let session = Session(name: "Imported Library")
        modelContext.insert(session)
        for asset in orphaned {
            asset.session = session
        }
        try? modelContext.save()
    }

    /// One-time cleanup for a dev-only mistake: an earlier iteration of stack-sharing (since
    /// reverted) gave `Stage` a fourth `StageKind` case, `.stack` (raw value 3), and created one
    /// per pre-existing `PhotoStack` on this machine's local dev database. That case no longer
    /// exists — `Stage.kind`'s getter falls back to `.custom` for any unrecognized raw value — so
    /// those leftover records were resurfacing as a bogus custom stage literally named "Stack".
    /// Deletes them by their still-persisted raw value, which is now dead and can't collide with
    /// anything `Stage.init` still writes. Not a concern for anyone else's database, since this
    /// case was never in a shipped build.
    private func cleanupLegacyStackKindStages() {
        guard let stages = try? modelContext.fetch(FetchDescriptor<Stage>()) else { return }
        let legacy = stages.filter { $0.kindRaw == 3 }
        guard !legacy.isEmpty else { return }
        for stage in legacy { modelContext.delete(stage) }
        try? modelContext.save()
    }

    /// `PhotoStack.stages` is a new relationship — existing stacks created before it existed have
    /// no `.single` stage on disk (SwiftData's lightweight migration adds the column but doesn't
    /// re-run `PhotoStack.init`, the only other place one gets created), so `PhotoAsset.singleStage`
    /// would silently fall back to each photo's own pre-stacking stage instead of actually sharing
    /// one. One-time fetch, not a `@Query`, since this only needs to run once at launch, not stay
    /// live — see `backfillMissingSessions` above for the same reasoning.
    private func backfillMissingStackStages() {
        guard let stacks = try? modelContext.fetch(FetchDescriptor<PhotoStack>()) else { return }
        var didChange = false
        for stack in stacks where stack.singleStage == nil {
            let stage = Stage(kind: .single, name: "Single", stack: stack)
            modelContext.insert(stage)
            stack.stages?.append(stage)
            didChange = true
        }
        guard didChange else { return }
        try? modelContext.save()
    }

    /// Built once, attached in one place (`detail`'s `.toolbar` above), and shared by both the grid
    /// and the editor now that the editor is swapped in rather than pushed — see the comment on the
    /// `Group` in `body` for why that's what makes the Mode picker persistent. The icon cluster only
    /// makes sense for the grid (sort/filter/organize/import all act on `allAssets`), so it's gated
    /// behind `editingAsset == nil`; the editor gets a single "Done" button in its place. The Mode
    /// picker itself is unconditional — it's the one control meant to survive the swap.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if detailStore.editingAsset == nil {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importFolder()
                } label: {
                    Label("Import Folder", systemImage: "folder.badge.plus")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                EditButton(store: detailStore, onEdit: {
                    if let id = detailStore.selection.first, let asset = allAssets.first(where: { $0.id == id }) {
                        openEditor(for: asset)
                    }
                })
            }
            ToolbarItem(placement: .primaryAction) {
                OrganizeMenu(
                    store: detailStore,
                    selectedScene: selectedScene,
                    onGroupStack: groupSelectedIntoStack,
                    onUnstack: unstackSelected,
                    onAddSelected: addSelected,
                    onNewScene: {
                        detailStore.addSelectionToNewScene = true
                        detailStore.newSceneName = ""
                        detailStore.newSceneSession = detailStore.commonSessionForSelection
                        detailStore.isShowingNewSceneAlert = true
                    },
                    onRemoveFromScene: removeSelectedFromCurrentScene
                )
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Sort", selection: $detailStore.sortOption) {
                        ForEach(SortOption.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Minimum Rating", selection: $detailStore.ratingFilter) {
                        Text("All Ratings").tag(0)
                        ForEach(1...5, id: \.self) { r in
                            Text("\(r)+ Stars").tag(r)
                        }
                    }
                    Divider()
                    Picker("Flag", selection: $detailStore.flagFilter) {
                        Text("All Flags").tag(FlagState?.none)
                        Text("Picked").tag(FlagState?.some(.pick))
                        Text("Rejected").tag(FlagState?.some(.reject))
                        Text("Unflagged").tag(FlagState?.some(.none))
                    }
                } label: {
                    Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        } else {
            ToolbarItem(placement: .primaryAction) {
                Button("Done") { closeEditor() }
            }
        }
        // NSToolbar lays items out left-to-right with no automatic trailing alignment on macOS —
        // `.confirmationAction` was tried first and rendered in the same leading cluster as
        // everything above, not the far right. A `Spacer()` item is what actually claims the
        // remaining flexible space and pushes what follows to the toolbar's far-right edge.
        ToolbarItem(placement: .primaryAction) {
            Spacer()
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Mode", selection: $detailStore.gridMode) {
                ForEach(GridMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    private func importFolder() {
        let recursiveOption = RecursiveImportOption()
        let accessory = NSHostingView(
            rootView: Toggle("Include Subfolders", isOn: Binding(
                get: { recursiveOption.recursive },
                set: { recursiveOption.recursive = $0 }
            ))
            .padding(10)
        )
        accessory.frame = NSRect(x: 0, y: 0, width: 240, height: 36)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Import"
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let files = LibraryImporter().scanFolder(at: url, recursive: recursiveOption.recursive)
        pendingImportFiles = files
        newSessionName = ""
        isShowingSessionPicker = true
    }

    private func performImport(files: [URL], session: Session) {
        let importer = LibraryImporter()
        do {
            let count = try importer.importFiles(files, into: modelContext, session: session)
            importStatus = "Imported \(count) new file\(count == 1 ? "" : "s") (\(files.count) RAW file\(files.count == 1 ? "" : "s") found)."
            refreshFilteredAssets()
        } catch {
            importStatus = "Import failed: \(error.localizedDescription)"
        }
    }

    private func groupSelectedIntoStack() {
        let selected = allAssets.filter { detailStore.selection.contains($0.id) }
        guard selected.count >= 2 else { return }

        var touchedStacks = Set<PhotoStack>()
        for asset in selected {
            if let old = asset.stack {
                touchedStacks.insert(old)
                asset.stack = nil
            }
        }
        let newStack = PhotoStack()
        modelContext.insert(newStack)
        for asset in selected {
            asset.stack = newStack
        }
        for old in touchedStacks where (old.photos?.isEmpty ?? true) {
            modelContext.delete(old)
        }
        try? modelContext.save()
        detailStore.refreshTrigger += 1
        refreshFilteredAssets()
    }

    private func unstackSelected() {
        let selected = allAssets.filter { detailStore.selection.contains($0.id) }
        var touchedStacks = Set<PhotoStack>()
        for asset in selected {
            if let stack = asset.stack {
                touchedStacks.insert(stack)
            }
        }
        for stack in touchedStacks {
            for member in stack.photos ?? [] {
                member.stack = nil
            }
            modelContext.delete(stack)
        }
        try? modelContext.save()
        detailStore.refreshTrigger += 1
        refreshFilteredAssets()
    }

    private func addSelected(to scene: PhotoScene) {
        let selected = allAssets.filter { detailStore.selection.contains($0.id) }
        for asset in selected {
            asset.scene = scene
        }
        try? modelContext.save()
        detailStore.refreshTrigger += 1
        refreshFilteredAssets()
    }

    private func removeSelectedFromCurrentScene() {
        guard let selectedScene else { return }
        let selected = allAssets.filter { detailStore.selection.contains($0.id) }
        for asset in selected where asset.scene?.id == selectedScene.id {
            asset.scene = nil
        }
        try? modelContext.save()
        detailStore.refreshTrigger += 1
        refreshFilteredAssets()
    }

    private func createScene(named name: String, addSelection: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = detailStore.newSceneSession else { return }
        let scene = PhotoScene(name: trimmed, session: session)
        modelContext.insert(scene)
        if addSelection {
            let selected = allAssets.filter { detailStore.selection.contains($0.id) }
            for asset in selected {
                asset.scene = scene
            }
        }
        try? modelContext.save()
        detailStore.newSceneName = ""
        detailStore.newSceneSession = nil
        selectedScene = scene
        selectedSession = session
        detailStore.refreshTrigger += 1
        refreshFilteredAssets()
    }

    private func quickCreateAndAssignScene(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = detailStore.commonSessionForSelection else { return }
        let scene = PhotoScene(name: trimmed, session: session)
        modelContext.insert(scene)
        let selected = allAssets.filter { detailStore.selection.contains($0.id) }
        for asset in selected {
            asset.scene = scene
        }
        try? modelContext.save()
        detailStore.quickSceneName = ""
        detailStore.isShowingScenePicker = false
        detailStore.refreshTrigger += 1
        refreshFilteredAssets()
    }

    private func deleteScene(_ scene: PhotoScene) {
        if selectedScene?.id == scene.id {
            selectedScene = nil
        }
        modelContext.delete(scene)
        try? modelContext.save()
        detailStore.refreshTrigger += 1
        refreshFilteredAssets()
    }
}

private final class RecursiveImportOption {
    var recursive = true
}
