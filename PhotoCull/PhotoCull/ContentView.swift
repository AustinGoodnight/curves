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
    /// Live, user-customizable UI chrome colors — see `ColorSchemeStore`'s doc comment. A plain
    /// Observable read, not `@Query`, so reading it directly in `body`/`toolbarContent` is safe
    /// (it only actually changes when the user edits Settings, unlike `allAssets` above).
    @Environment(ColorSchemeStore.self) private var uiColors
    @Query(sort: \PhotoAsset.captureDate, order: .reverse) private var allAssets: [PhotoAsset]
    @Query(sort: \PhotoScene.name) private var scenes: [PhotoScene]
    @Query(sort: \Session.createdDate, order: .reverse) private var sessions: [Session]

    @State private var selectedScene: PhotoScene?
    @State private var selectedSession: Session?
    /// Persists which session was last opened so the sidebar/grid reopen to it — there's no more
    /// "All Photos" library view to fall back to. Restored once in `.task` below (sessions may not
    /// be selectable yet at `@State` init time), and updated on every `selectedSession` change.
    @AppStorage("lastOpenedSessionID") private var lastOpenedSessionIDString = ""
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

    /// Body itself is just `rootView` plus every `.onChange`/`.task` side-effect hook, kept as a
    /// separate expression from `rootView` (which carries `NavigationSplitView` plus its
    /// `.background`/`.alert`/`.sheet` chain) purely so Swift's type-checker has two smaller
    /// expressions to solve instead of one giant one — seven `.onChange` handlers plus `.task`
    /// chained directly onto the alert/sheet chain below was enough, once `isCullingViewActive`'s
    /// handler was added, to blow past the checker's time limit (`error: the compiler is unable to
    /// type-check this expression in reasonable time`) with no behavior change either side of the
    /// split.
    var body: some View {
        rootView
            .onChange(of: detailStore.selection) { _, _ in detailStore.refreshSelectionDerivedState(allAssets: allAssets, scenes: scenes) }
            .onChange(of: detailStore.editingAsset) { _, newValue in
                detailStore.refreshSelectionDerivedState(allAssets: allAssets, scenes: scenes)
                updateSidebarVisibility()
                // Keeps the toolbar's Sessions/Edit switcher truthful when the editor opens or
                // closes through any path *other* than clicking that switcher itself — the
                // hover-revealed edit button, Return in the culling view, `StagesSidebarView`'s
                // "Stack" section jumping straight from one photo to another. Safe against
                // feedback with the `onChange(of: detailStore.gridMode)` handler below: that
                // handler's own guards (`editingAsset == nil` / `!= nil`) already no-op once
                // `editingAsset` matches the mode being set here, so this never re-triggers it.
                detailStore.gridMode = newValue != nil ? .edit : .sessions
            }
            .onChange(of: detailStore.isCullingViewActive) { _, _ in
                updateSidebarVisibility()
            }
            .onChange(of: selectedScene) { _, _ in refreshFilteredAssets() }
            .onChange(of: selectedSession) { _, newValue in
                refreshFilteredAssets()
                lastOpenedSessionIDString = newValue?.id.uuidString ?? ""
            }
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
                restoreLastOpenedSession()
                refreshFilteredAssets()
            }
    }

    private var rootView: some View {
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
            // See `detailContent`'s doc comment for why the grid/editor/culling-view switch lives
            // in its own computed property rather than inline here.
            detailContent
                .navigationTitle(detailStore.editingAsset?.fileName ?? selectedScene?.name ?? selectedSession?.name ?? "PhotoCull")
                .toolbar { toolbarContent }
                .toolbarBackground(uiColors.sidebarBackground, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        }
        .background(WindowBackgroundConfigurator(color: uiColors.sidebarBackground))
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
            Button("Cancel", role: .cancel) {
                detailStore.newSceneName = ""
                detailStore.newSceneSession = nil
                detailStore.pendingSceneAssetIDs = []
            }
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
    }

    private func refreshFilteredAssets() {
        detailStore.refreshFilteredAssets(allAssets: allAssets, selectedScene: selectedScene, selectedSession: selectedSession)
    }

    /// The Library/Sessions/Scenes sidebar has nothing to do with editing or reviewing a single
    /// photo — collapsed by default (still manually reopenable) whenever either full-window mode
    /// is active, same reasoning as the editor's own sidebar-collapse behavior documented on
    /// `sidebarVisibility`'s declaration.
    private func updateSidebarVisibility() {
        sidebarVisibility = (detailStore.editingAsset != nil || detailStore.isCullingViewActive) ? .detailOnly : .all
    }

    /// Runs once at launch, after `backfillMissingSessions()` so a brand-new "Imported Library"
    /// session (if any) is already in `sessions`. Prefers the persisted last-opened session; if
    /// that session was deleted (or this is the first launch since this feature shipped, so
    /// nothing's persisted yet) falls back to the most recent session, if any exist. Leaves
    /// `selectedSession` `nil` — showing no session — only when the library truly has none.
    private func restoreLastOpenedSession() {
        guard selectedSession == nil else { return }
        if let uuid = UUID(uuidString: lastOpenedSessionIDString),
           let match = sessions.first(where: { $0.id == uuid }) {
            selectedSession = match
        } else {
            selectedSession = sessions.first
        }
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

    /// Pulled out of `body` into its own computed property purely to keep the type-checker fast —
    /// a 3-way `if`/`else if`/`else` `Group` with a long trailing modifier chain (`.navigationTitle`/
    /// `.toolbar`/two `.toolbarBackground`s) directly inline in `NavigationSplitView`'s `detail:`
    /// closure pushed Swift's expression type-checker over its time limit (`error: the compiler is
    /// unable to type-check this expression in reasonable time`); splitting the branch itself into
    /// a separate expression the compiler can solve on its own fixes that with no behavior change.
    /// Grid and editor (and now the culling view) are swapped in place here rather than pushed via
    /// `navigationDestination` (as it used to be) — that let each screen have its own toolbar,
    /// which is exactly what made the Sessions/Edit toggle *not* persistent: it simply didn't exist
    /// on the editor's separate toolbar. One shared `toolbarContent`, attached once at this
    /// property's use site, is what makes it persistent across all three. `editingAsset == nil`/
    /// `isCullingViewActive` still gate `GridPane`'s and `CullingPresentationView`'s *construction*
    /// here, not just their bodies — see this file's header comment (trap #3) for why that
    /// distinction matters. `.id(editingAsset.id)` on the editor branch forces a fresh `EditorView`
    /// (fresh `@State` coordinator/stage) every time `editingAsset` changes — including a direct
    /// switch from one photo to another via `SessionFilmstripView`/`StagesSidebarView`'s "Stack"
    /// section, which never passes through `nil`. Without this, the `if`/`else` branch alone gives
    /// SwiftUI no reason to recreate the view for a same-branch identity change, and the
    /// coordinator/stage state from the *previous* photo would leak into the new one.
    @ViewBuilder
    private var detailContent: some View {
        if let editingAsset = detailStore.editingAsset {
            EditorView(asset: editingAsset, onSelectAsset: openEditor)
                .id(editingAsset.id)
        } else if detailStore.isCullingViewActive {
            CullingPresentationView(
                store: detailStore,
                onOpenEditor: openEditor,
                onDataChanged: { detailStore.refreshFilteredAssets(allAssets: allAssets, selectedScene: selectedScene, selectedSession: selectedSession) },
                onCreateScene: beginSceneCreation
            )
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

    /// Built once, attached in one place (`detail`'s `.toolbar` above), and shared by both the grid
    /// and the editor now that the editor is swapped in rather than pushed — see the comment on the
    /// `Group` in `body` for why that's what makes the Mode switcher persistent. The icon cluster
    /// only makes sense for the grid (sort/filter/organize/import all act on `allAssets`), so it's
    /// gated behind `editingAsset == nil`; the editor shows none of them. The Mode switcher itself
    /// is unconditional — it's the one control meant to survive the swap, and (now that
    /// `onChange(of: detailStore.editingAsset)` above keeps it in sync) it's also how the editor
    /// closes: clicking "Sessions" while editing is what used to be a separate "Done" button.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Replaces the plain `.navigationTitle` text in the window's (hidden-title-bar) toolbar
        // with the app's own wordmark — `.principal` is the one placement that overrides the
        // native title text on macOS. The asset is a template image (see its Contents.json) so
        // it tints via `.foregroundStyle` instead of rendering its own (default-black, invisible
        // against this app's forced-dark theme) SVG fill.
        ToolbarItem(placement: .principal) {
            Image("CurvesWordmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 12)
                .foregroundStyle(.primary)
        }
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
                RatingFilterControl(store: detailStore)
            }
            ToolbarItem(placement: .primaryAction) {
                FlagFilterControl(store: detailStore)
            }
            ToolbarItem(placement: .primaryAction) {
                Toggle(isOn: $detailStore.isCullingViewActive) {
                    Label("Culling View", systemImage: "rectangle.center.inset.filled")
                }
                .toggleStyle(.button)
                .help("Culling View — review and grade one photo at a time")
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
            ModeSwitcherControl(store: detailStore)
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
            let imported = try importer.importFiles(files, into: modelContext, session: session)
            // Applies the "Default Stage" preset (if any) to each newly-imported photo's own
            // `.single` stage — see `StageFieldSnapshot.applyDefaultIfAvailable(to:context:)`. Not
            // done inside `LibraryImporter` itself: that lives in the PhotoCatalog package, which
            // has no visibility into `Preset`/`StageFieldSnapshot` (both app-target types).
            for asset in imported {
                StageFieldSnapshot.applyDefaultIfAvailable(to: asset.singleStage, context: modelContext)
            }
            let count = imported.count
            importStatus = "Imported \(count) new file\(count == 1 ? "" : "s") (\(files.count) file\(files.count == 1 ? "" : "s") found)."
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

    /// `pendingSceneAssetIDs` (set by `beginSceneCreation(for:)`, the culling view's "S" scene-mark
    /// shortcut) takes priority over `addSelection`/`selection` when present — see its doc comment
    /// on `DetailStore` for why.
    private func createScene(named name: String, addSelection: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = detailStore.newSceneSession else { return }
        let scene = PhotoScene(name: trimmed, session: session)
        modelContext.insert(scene)
        if !detailStore.pendingSceneAssetIDs.isEmpty {
            let targeted = allAssets.filter { detailStore.pendingSceneAssetIDs.contains($0.id) }
            for asset in targeted {
                asset.scene = scene
            }
            detailStore.pendingSceneAssetIDs = []
        } else if addSelection {
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

    /// Wired to `CullingPresentationView.onCreateScene`, fired when the culling view's "S"
    /// scene-mark shortcut closes a range. Reuses the same "New Scene" naming alert every other
    /// scene-creation path uses (`detailStore.isShowingNewSceneAlert`) rather than a bespoke one —
    /// `createScene(named:addSelection:)` picks up `pendingSceneAssetIDs` set here ahead of
    /// `selection` once the user actually names and confirms it. Silently does nothing if the
    /// marked range spans more than one session — a scene can't straddle sessions, and there's no
    /// sensible single session to pre-fill the alert with, so surfacing this as a hard error would
    /// be disproportionate to a rare mis-mark.
    private func beginSceneCreation(for rangeAssets: [PhotoAsset]) {
        guard let first = rangeAssets.first?.session, rangeAssets.allSatisfy({ $0.session?.id == first.id }) else { return }
        detailStore.pendingSceneAssetIDs = Set(rangeAssets.map(\.id))
        detailStore.newSceneName = ""
        detailStore.newSceneSession = first
        detailStore.isShowingNewSceneAlert = true
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

/// Sets the `NSWindow`'s own `backgroundColor` directly, rather than relying solely on
/// `.toolbarBackground(_:for:)` — that modifier's custom tint doesn't reliably survive the
/// transition into macOS fullscreen (a distinct window/space from the windowed one), which is what
/// let the toolbar fall back to the system's default dark-mode window background — a lighter
/// charcoal grey — instead of this app's own much darker palette there. `titlebarAppearsTransparent`
/// lets that color show straight through the title bar/toolbar region; `backgroundColor` is a
/// window-level AppKit property, not a per-space toolbar material, so macOS carries it into
/// fullscreen intact. An `NSViewRepresentable` purely to reach the `NSWindow` a SwiftUI view is
/// hosted in — it renders nothing itself. `view.window` isn't set yet at `makeNSView` time (the
/// view isn't in the hierarchy), and one deferred `DispatchQueue.main.async` wasn't reliably enough
/// — `apply()` retries every 0.05s (capped) until the window actually exists, and `updateNSView`
/// re-applies on every SwiftUI update pass so a window-recreation (fullscreen/Space changes on some
/// macOS versions do this) can't silently drop the override again.
///
/// `updateNSView` alone still isn't a complete guarantee — it only reruns when *SwiftUI* decides
/// this view's inputs changed, not on every AppKit-level event that can reset a window's own
/// background (a plain resize, becoming key again after losing it, moving to a different screen).
/// The `Coordinator` additionally observes those window notifications directly and reapplies on
/// each one, so a stale system-grey toolbar from one of those events self-heals without needing an
/// unrelated SwiftUI state change to happen to trigger `updateNSView` first.
private struct WindowBackgroundConfigurator: NSViewRepresentable {
    /// Passed in from `ContentView` (`colorScheme.sidebarBackground`) rather than read as a fixed
    /// constant — `updateNSView` already re-applies on every SwiftUI update pass (see below), so a
    /// live Settings change to the sidebar color reaches the window chrome the same way.
    let color: Color

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        apply(to: view, attempt: 0)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView, attempt: 0)
        context.coordinator.observe(nsView, color: color)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func apply(to view: NSView, attempt: Int) {
        guard let window = view.window else {
            guard attempt < 20 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                apply(to: view, attempt: attempt + 1)
            }
            return
        }
        Self.style(window, color: color)
    }

    fileprivate static func style(_ window: NSWindow, color: Color) {
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(color)
    }

    final class Coordinator {
        private var observedWindow: NSWindow?
        private var tokens: [NSObjectProtocol] = []

        /// Re-registers only when `view.window` actually changed identity (a resize/key/screen
        /// notification would otherwise be registered again on every single SwiftUI update pass,
        /// piling up duplicate observers forever).
        func observe(_ view: NSView, color: Color) {
            guard let window = view.window, window !== observedWindow else { return }
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll()
            observedWindow = window
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification] {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    guard let window else { return }
                    WindowBackgroundConfigurator.style(window, color: color)
                }
                tokens.append(token)
            }
            // The actual, confirmed trigger (per direct user report, not assumed): entering
            // fullscreen specifically, not just any resize — `didResizeNotification` above fires
            // during the fullscreen transition too, but AppKit's own transition animation appears
            // to repaint the toolbar *after* that, silently reasserting its default system
            // material. Reapplying again shortly after `didEnterFullScreenNotification` (once that
            // animation has actually finished, not mid-flight) is what actually sticks.
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    guard let window else { return }
                    WindowBackgroundConfigurator.style(window, color: color)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak window] in
                        guard let window else { return }
                        WindowBackgroundConfigurator.style(window, color: color)
                    }
                }
                tokens.append(token)
            }
        }

        deinit {
            tokens.forEach(NotificationCenter.default.removeObserver)
        }
    }
}
