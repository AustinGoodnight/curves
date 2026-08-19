import SwiftUI
import SwiftData
import AppKit
import PhotoCatalog

/// ⚠️ PERFORMANCE TRAP, hit three times now — see `CLAUDE.md` at the repo root for the full
/// writeup. The short version: **never read an expensive computed property (anything that
/// filters/scans `allAssets`/`scenes`/`sessions`) directly inside `body`/`toolbarContent`.** A
/// computed property reruns on *every* re-render of this view, for any reason — `ContentView`
/// stays mounted behind the pushed `EditorView` and reruns on every editor slider tick, and it
/// obviously also reruns on every plain `selection` change while browsing the grid. Gating a
/// computed property behind `editingAsset == nil` only patches the first trigger and leaves the
/// second one just as slow (this was tried once and wasn't enough — see `CLAUDE.md`).
///
/// The actual fix, and the pattern to copy: cache the value in `@State` and recompute only from
/// `.onChange(of:)` on its real inputs — see `commonSessionForSelection`/`scenesInCommonSession`/
/// `refreshSelectionDerivedState()` below.
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PhotoAsset.captureDate, order: .reverse) private var allAssets: [PhotoAsset]
    @Query(sort: \PhotoScene.name) private var scenes: [PhotoScene]
    @Query(sort: \Session.createdDate, order: .reverse) private var sessions: [Session]

    @State private var selectedScene: PhotoScene?
    @State private var selectedSession: Session?
    @State private var selection: Set<UUID> = []
    @State private var ratingFilter: Int = 0
    @State private var flagFilter: FlagState?
    @State private var sortOption: SortOption = .captureDateDesc
    @State private var importStatus: String?
    @State private var isShowingNewSceneAlert = false
    @State private var newSceneName = ""
    @State private var addSelectionToNewScene = false
    @State private var refreshTrigger = 0
    @State private var editingAsset: PhotoAsset?
    @State private var isShowingSessionPicker = false
    @State private var pendingImportFiles: [URL] = []
    @State private var newSessionName = ""
    @State private var newSceneSession: Session?
    @State private var isShowingScenePicker = false
    @State private var quickSceneName = ""
    @State private var gridMode: GridMode = .sessions

    enum SortOption: String, CaseIterable, Identifiable {
        case captureDateDesc = "Newest First"
        case captureDateAsc = "Oldest First"
        case ratingDesc = "Highest Rated"
        case fileName = "File Name"
        var id: String { rawValue }
    }

    /// "Sessions": a click selects, for rating/flagging/stacking/scene-assigning. "Edit": a click
    /// opens the editor immediately, one photo at a time. See `CullingGridView.isEditMode`'s doc
    /// comment for the tradeoff between the two.
    enum GridMode: String, CaseIterable, Identifiable {
        case sessions = "Sessions"
        case edit = "Edit"
        var id: String { rawValue }
    }

    /// The single session shared by every currently-selected asset, or `nil` if the selection is
    /// empty or spans more than one session. Scene assignment is scoped to one session at a time
    /// (a scene lives inside exactly one session), so "Add Selected to Scene" needs this to know
    /// which session's scenes to offer.
    ///
    /// **Cached `@State`, not a computed property** — read the warning at the top of this file.
    /// This used to be a computed property read directly inside `toolbarContent`'s body, which
    /// meant it re-ran `allAssets.filter(...)` (1000s of `PhotoAsset`s on a real library) on
    /// *every* SwiftUI re-diff of `ContentView`, not just when the selection actually changed —
    /// including every slider tick while the editor was open, and every single click while just
    /// selecting photos in the grid. A guard for "skip while the editor is open" only patches one
    /// of those triggers; caching removes the problem at the root by only recomputing on the one
    /// event that can actually change the answer (`.onChange(of: selection)` /
    /// `.onChange(of: editingAsset)`, wired in `body`).
    @State private var commonSessionForSelection: Session?
    /// Scenes in the session all selected assets share — refreshed alongside
    /// `commonSessionForSelection` by the same `refreshSelectionDerivedState()` call.
    @State private var scenesInCommonSession: [PhotoScene] = []

    /// Recomputes `commonSessionForSelection`/`scenesInCommonSession` — call only from
    /// `.onChange(of: selection)`/`.onChange(of: editingAsset)`, never from `body` itself (that's
    /// the exact mistake this replaced; see the doc comment above).
    private func refreshSelectionDerivedState() {
        guard editingAsset == nil, !selection.isEmpty else {
            commonSessionForSelection = nil
            scenesInCommonSession = []
            return
        }
        let selected = allAssets.filter { selection.contains($0.id) }
        guard let first = selected.first?.session, selected.allSatisfy({ $0.session?.id == first.id }) else {
            commonSessionForSelection = nil
            scenesInCommonSession = []
            return
        }
        commonSessionForSelection = first
        scenesInCommonSession = scenes.filter { $0.session?.id == first.id }
    }

    private var filteredAssets: [PhotoAsset] {
        var result = allAssets
        if let selectedScene {
            result = result.filter { $0.scene?.id == selectedScene.id }
        } else if let selectedSession {
            result = result.filter { $0.session?.id == selectedSession.id }
        }
        if ratingFilter > 0 {
            result = result.filter { $0.rating >= ratingFilter }
        }
        if let flagFilter {
            result = result.filter { $0.flag == flagFilter }
        }
        switch sortOption {
        case .captureDateDesc:
            result.sort { ($0.captureDate ?? $0.importDate) > ($1.captureDate ?? $1.importDate) }
        case .captureDateAsc:
            result.sort { ($0.captureDate ?? $0.importDate) < ($1.captureDate ?? $1.importDate) }
        case .ratingDesc:
            result.sort { $0.rating > $1.rating }
        case .fileName:
            result.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        }
        return result
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                sessions: sessions,
                scenes: scenes,
                selectedSession: $selectedSession,
                selectedScene: $selectedScene,
                onNewScene: { session in
                    addSelectionToNewScene = false
                    newSceneName = ""
                    newSceneSession = session
                    isShowingNewSceneAlert = true
                },
                onDeleteScene: deleteScene
            )
        } detail: {
            NavigationStack {
                // Gated on `editingAsset == nil` rather than always constructing the grid: this
                // view is pushed via `navigationDestination` below, not presented modally, so
                // `CullingGridView` stays mounted underneath the editor for back-navigation.
                // `filteredAssets` re-filters/re-sorts the whole library and `CullingGridView`'s
                // own `displayItems` redoes an O(n²)-ish stack-grouping pass — both uncached,
                // both re-evaluated by SwiftUI's `@Query` on *any* tracked-property change to
                // *any* fetched `PhotoAsset`, which includes every single edit made while the
                // editor is open. On a real library that's expensive enough to stall the main
                // thread for a few hundred ms per slider tick — this is what was actually behind
                // "renders fine once you release, but does nothing while sliding": the render
                // pipeline itself was never the bottleneck, this hidden background recompute was.
                Group {
                    if editingAsset == nil {
                        CullingGridView(
                            assets: filteredAssets,
                            selection: $selection,
                            isEditMode: gridMode == .edit,
                            onGroupStack: groupSelectedIntoStack,
                            onUnstack: unstackSelected,
                            onOpenEditor: { editingAsset = $0 }
                        )
                        .id(refreshTrigger)
                        .overlay {
                            if allAssets.isEmpty {
                                ContentUnavailableView(
                                    "No Photos",
                                    systemImage: "photo.on.rectangle.angled",
                                    description: Text("Import a folder of RAW files to get started.")
                                )
                            } else if filteredAssets.isEmpty {
                                ContentUnavailableView(
                                    "No Matches",
                                    systemImage: "line.3.horizontal.decrease.circle",
                                    description: Text("No photos match the current filter.")
                                )
                            }
                        }
                    }
                }
                .navigationTitle(selectedScene?.name ?? selectedSession?.name ?? "PhotoCull")
                .toolbar { toolbarContent }
                .toolbarBackground(Color.sidebarBackground, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
                .navigationDestination(item: $editingAsset) { asset in
                    EditorView(asset: asset)
                }
            }
        }
        // ⌘S as a hidden `Button` + `.keyboardShortcut`, not a case in `CullingGridView`'s
        // `onKeyPress` handler (where the rest of the grid's shortcuts live): AppKit routes
        // Command-modified key combos through the menu bar's key-equivalent system *before* they
        // ever reach a view's `onKeyPress`, so a Command chord typed there is unreliable — it
        // depends on nothing else claiming the equivalent first, and in practice often just never
        // arrives. `.keyboardShortcut` registers a real key equivalent the standard way and fires
        // regardless of which view has focus, which is what a menu-adjacent shortcut like this
        // needs anyway. No-ops harmlessly when there's no valid single-session selection to act on
        // (`commonSessionForSelection` is `nil`, e.g. nothing selected or the editor is open).
        .background {
            Button("Add Selected to Scene") {
                guard commonSessionForSelection != nil else { return }
                quickSceneName = ""
                isShowingScenePicker = true
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
        .alert("New Scene", isPresented: $isShowingNewSceneAlert) {
            TextField("Scene Name", text: $newSceneName)
            Button("Cancel", role: .cancel) { newSceneName = ""; newSceneSession = nil }
            Button("Create") { createScene(named: newSceneName, addSelection: addSelectionToNewScene) }
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
        .sheet(isPresented: $isShowingScenePicker) {
            ScenePickerSheet(
                scenes: scenesInCommonSession,
                newSceneName: $quickSceneName,
                onPick: { scene in
                    addSelected(to: scene)
                    isShowingScenePicker = false
                },
                onCreate: { name in quickCreateAndAssignScene(named: name) },
                onCancel: { isShowingScenePicker = false }
            )
        }
        .onChange(of: selection) { _, _ in refreshSelectionDerivedState() }
        .onChange(of: editingAsset) { _, _ in refreshSelectionDerivedState() }
        .task { backfillMissingSessions() }
    }

    /// One-time migration for photos imported before the Session model existed (Phase 0 of the
    /// Stages feature): every `PhotoAsset.session` on this app's real library was `nil`, which
    /// silently broke every session-scoped action — "Add Selected to Scene", ⌘S, and the scene
    /// itself never showing up under any session in the sidebar (`SidebarView` only lists scenes
    /// nested under a session row). Rather than threading "nil session is a valid shared value"
    /// through `commonSessionForSelection`/scene creation/the sidebar, this backs every orphaned
    /// asset into one shared session so the rest of the app's "a scene lives inside one session"
    /// invariant just holds. Idempotent — `orphaned` is empty on every run after the first.
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                importFolder()
            } label: {
                Label("Import Folder", systemImage: "folder.badge.plus")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                if let id = selection.first, let asset = allAssets.first(where: { $0.id == id }) {
                    editingAsset = asset
                }
            } label: {
                Label("Edit…", systemImage: "slider.horizontal.3")
            }
            .disabled(selection.count != 1)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Group Selected into Stack (G)") { groupSelectedIntoStack() }
                    .disabled(selection.count < 2)
                Button("Unstack Selected (⇧G)") { unstackSelected() }
                    .disabled(selection.isEmpty)
                Divider()
                Menu("Add Selected to Scene") {
                    ForEach(scenesInCommonSession) { scene in
                        Button(scene.name) { addSelected(to: scene) }
                    }
                    if !scenesInCommonSession.isEmpty { Divider() }
                    Button("New Scene…") {
                        addSelectionToNewScene = true
                        newSceneName = ""
                        newSceneSession = commonSessionForSelection
                        isShowingNewSceneAlert = true
                    }
                }
                .disabled(commonSessionForSelection == nil)
                if selectedScene != nil {
                    Button("Remove Selected from This Scene") { removeSelectedFromCurrentScene() }
                        .disabled(selection.isEmpty)
                }
            } label: {
                Label("Organize", systemImage: "square.stack.3d.up")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Sort", selection: $sortOption) {
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
                Picker("Minimum Rating", selection: $ratingFilter) {
                    Text("All Ratings").tag(0)
                    ForEach(1...5, id: \.self) { r in
                        Text("\(r)+ Stars").tag(r)
                    }
                }
                Divider()
                Picker("Flag", selection: $flagFilter) {
                    Text("All Flags").tag(FlagState?.none)
                    Text("Picked").tag(FlagState?.some(.pick))
                    Text("Rejected").tag(FlagState?.some(.reject))
                    Text("Unflagged").tag(FlagState?.some(.none))
                }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Picker("Mode", selection: $gridMode) {
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
        } catch {
            importStatus = "Import failed: \(error.localizedDescription)"
        }
    }

    private func groupSelectedIntoStack() {
        let selected = allAssets.filter { selection.contains($0.id) }
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
        refreshTrigger += 1
    }

    private func unstackSelected() {
        // Selecting a collapsed stack only selects its cover photo, so unstacking must
        // dissolve every member of any touched stack — not just the selected asset —
        // or the other members are silently left behind in an orphaned singleton stack.
        let selected = allAssets.filter { selection.contains($0.id) }
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
        refreshTrigger += 1
    }

    private func addSelected(to scene: PhotoScene) {
        // Singular assignment: a photo belongs to at most one scene, so adding to a new scene
        // reassigns rather than appends.
        let selected = allAssets.filter { selection.contains($0.id) }
        for asset in selected {
            asset.scene = scene
        }
        try? modelContext.save()
        refreshTrigger += 1
    }

    private func removeSelectedFromCurrentScene() {
        guard let selectedScene else { return }
        let selected = allAssets.filter { selection.contains($0.id) }
        for asset in selected where asset.scene?.id == selectedScene.id {
            asset.scene = nil
        }
        try? modelContext.save()
        refreshTrigger += 1
    }

    private func createScene(named name: String, addSelection: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = newSceneSession else { return }
        let scene = PhotoScene(name: trimmed, session: session)
        modelContext.insert(scene)
        if addSelection {
            let selected = allAssets.filter { selection.contains($0.id) }
            for asset in selected {
                asset.scene = scene
            }
        }
        try? modelContext.save()
        newSceneName = ""
        newSceneSession = nil
        selectedScene = scene
        selectedSession = session
        refreshTrigger += 1
    }

    /// ⌘S's "New Scene Name" field — same shape as `createScene(named:addSelection:)` but scoped
    /// directly to `commonSessionForSelection` rather than the alert's `newSceneSession` state, so
    /// it works as a one-shot action straight from the grid without going through that alert flow.
    private func quickCreateAndAssignScene(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let session = commonSessionForSelection else { return }
        let scene = PhotoScene(name: trimmed, session: session)
        modelContext.insert(scene)
        let selected = allAssets.filter { selection.contains($0.id) }
        for asset in selected {
            asset.scene = scene
        }
        try? modelContext.save()
        quickSceneName = ""
        isShowingScenePicker = false
        refreshTrigger += 1
    }

    private func deleteScene(_ scene: PhotoScene) {
        if selectedScene?.id == scene.id {
            selectedScene = nil
        }
        modelContext.delete(scene)
        try? modelContext.save()
        refreshTrigger += 1
    }
}

private final class RecursiveImportOption {
    var recursive = true
}
