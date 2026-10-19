import SwiftUI
import SwiftData
import AppKit
import PhotoCatalog

/// ⚠️ PERFORMANCE TRAP — see `docs/PERFORMANCE.md` for the full writeup. Short version:
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
    /// The folder just scanned by `importFolder()`, carried through to the session picker sheet so
    /// `onCreate` can bind the new `Session` to it. Only ever shown to the user (and thus only ever
    /// needed) when no existing session already matches this folder — see `importFolder()`.
    @State private var pendingImportFolderURL: URL?
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
                detailStore.rebuildFilmstripItems()
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
            .onChange(of: detailStore.fileTypeFilter) { _, _ in refreshFilteredAssets() }
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
                await migrateToSidecarsIfNeeded()
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
                onDeleteScene: deleteScene,
                onImportFolder: importFolder
            )
            .equatable()
        } detail: {
            // See `detailContent`'s doc comment for why the grid/editor/culling-view switch lives
            // in its own computed property rather than inline here.
            detailContent
                .navigationTitle(detailStore.editingAsset?.fileName ?? selectedScene?.name ?? selectedSession?.name ?? "Curves")
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
        .background {
            // Mirrors `GridZoomControl`'s toolbar buttons — only meaningful against the session
            // grid, so disabled while editing or in the culling view (both hide the grid, and
            // `gridColumnCount` would have nothing visible to zoom).
            Group {
                Button("Zoom In") { detailStore.zoomInGrid() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Zoom Out") { detailStore.zoomOutGrid() }
                    .keyboardShortcut("-", modifiers: .command)
            }
            .disabled(detailStore.editingAsset != nil || detailStore.isCullingViewActive)
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
                newSessionName: $newSessionName,
                onCreate: { name in
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, let folderURL = pendingImportFolderURL else { return }
                    let session = Session(name: trimmed, folderURL: folderURL)
                    modelContext.insert(session)
                    KnownSessionFolders.record(session)
                    isShowingSessionPicker = false
                    performImport(files: pendingImportFiles, session: session)
                    pendingImportFiles = []
                    pendingImportFolderURL = nil
                    newSessionName = ""
                },
                onCancel: {
                    isShowingSessionPicker = false
                    pendingImportFiles = []
                    pendingImportFolderURL = nil
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
        asset.lastEditedDate = Date()
        detailStore.editingAsset = asset
    }

    private func closeEditor() {
        try? modelContext.save()
        // `EditHistory.commit()` writes this asset's own `.curve` and the scene/stack manifest
        // promptly on every settled edit, but deliberately does *not* fan out to every other
        // member's `.curve` on each tick (see its doc comment) — so a sibling's redundant
        // `sceneStageCopy`/routed stage fields can lag until it's next written for its own reason.
        // Closing the editor is a natural, low-frequency point to catch it up: only one asset can
        // ever be open at a time, so "every sibling of whatever was just being edited" is the whole
        // set that could have gone stale this session.
        if let asset = detailStore.editingAsset {
            if let scene = asset.scene { persistSidecars(for: scene.photos ?? []) }
            if let stack = asset.stack { persistSidecars(for: stack.photos ?? []) }
        }
        detailStore.editingAsset = nil
    }

    /// One-time migration for a store that predates sidecar persistence — gated by a `UserDefaults`
    /// flag, and safe to interrupt: every step only ever writes what's *missing* (an empty
    /// `folderPath`, a sidecar that doesn't exist on disk yet), never overwrites something already
    /// there, so a partial pass just means the next launch's pass picks up wherever this one left
    /// off, rather than redoing or corrupting anything. Writes are `await`ed directly (not the
    /// fire-and-forget `persistSidecars(for:)` every live-editing call site uses) specifically so
    /// this function can't mark itself done before the sidecars it just wrote actually reached disk.
    private func migrateToSidecarsIfNeeded() async {
        let flagKey = "hasMigratedToSidecars"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }

        // Backfill folder identity on any `Session` that predates it (`folderPath` defaults to ""
        // via SwiftData's lightweight migration for a field that didn't exist before). Majority
        // folder wins; any asset whose file lives elsewhere is split into its own new, per-folder
        // Session — a Session must map 1:1 to a folder going forward (see its doc comment), and
        // this is the one place an existing Session might not already satisfy that.
        let sessions = (try? modelContext.fetch(FetchDescriptor<Session>())) ?? []
        for session in sessions where session.folderPath.isEmpty {
            let members = session.photos ?? []
            guard !members.isEmpty else { continue }
            let byFolder = Dictionary(grouping: members) { $0.resolvedURL().deletingLastPathComponent() }
            guard let majorityFolder = byFolder.max(by: { $0.value.count < $1.value.count })?.key else { continue }
            session.folderPath = majorityFolder.path
            session.folderBookmarkData = try? majorityFolder.bookmarkData(options: [.minimalBookmark])
            KnownSessionFolders.record(session)
            for (folder, strayMembers) in byFolder where folder != majorityFolder {
                let straySession = Session(name: "\(session.name) (split)", folderURL: folder)
                modelContext.insert(straySession)
                KnownSessionFolders.record(straySession)
                for asset in strayMembers { asset.session = straySession }
            }
        }

        let assets = (try? modelContext.fetch(FetchDescriptor<PhotoAsset>())) ?? []
        for asset in assets where !FileManager.default.fileExists(atPath: asset.sidecarURL().path) {
            await SidecarWriter.shared.write(CurveSidecar(capturing: asset), to: asset.sidecarURL())
        }
        let scenes = (try? modelContext.fetch(FetchDescriptor<PhotoScene>())) ?? []
        for scene in scenes {
            guard let session = scene.session else { continue }
            let url = session.sceneManifestURL(sceneID: scene.id)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            await SidecarWriter.shared.write(SceneSidecar(capturing: scene), to: url)
        }
        let stacks = (try? modelContext.fetch(FetchDescriptor<PhotoStack>())) ?? []
        for stack in stacks {
            guard let session = stack.photos?.first?.session else { continue }
            let url = session.stackManifestURL(stackID: stack.id)
            guard !FileManager.default.fileExists(atPath: url.path) else { continue }
            await SidecarWriter.shared.write(StackSidecar(capturing: stack), to: url)
        }

        try? modelContext.save()
        UserDefaults.standard.set(true, forKey: flagKey)
    }

    /// One session per distinct containing folder, not one shared catch-all — `Session` now maps
    /// 1:1 to a folder (see its doc comment), and orphaned assets found here could in principle
    /// come from anywhere, so a single shared session would risk violating that invariant the
    /// moment two orphans turn out to live in different folders.
    private func backfillMissingSessions() {
        let orphaned = allAssets.filter { $0.session == nil }
        guard !orphaned.isEmpty else { return }
        let byFolder = Dictionary(grouping: orphaned) { $0.resolvedURL().deletingLastPathComponent() }
        for (folderURL, assets) in byFolder {
            let session = Session(name: "Imported Library", folderURL: folderURL)
            modelContext.insert(session)
            KnownSessionFolders.record(session)
            for asset in assets {
                asset.session = session
            }
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
    /// distinction matters. `.id(editingAsset.id)` on `EditorView` forces a fresh one (fresh
    /// `@State` coordinator/stage) every time `editingAsset` changes — including a direct switch
    /// from one photo to another via `SessionFilmstripView`/`StagesSidebarView`'s "Stack" section,
    /// which never passes through `nil`. Without this, the `if`/`else` branch alone gives SwiftUI no
    /// reason to recreate the view for a same-branch identity change, and the coordinator/stage
    /// state from the *previous* photo would leak into the new one. `SessionFilmstripView` sits
    /// *outside* that `.id()`, as `EditorView`'s sibling rather than its child — it has no per-photo
    /// `@State` that needs resetting, and living outside the `.id()` boundary is what lets clicking
    /// a thumbnail in it update in place instead of tearing down and rebuilding the whole panel
    /// (which also used to reset its scroll position to the top on every click).
    ///
    /// `HSplitView`, not a plain `HStack` — an `HStack` doesn't stretch its children to the full
    /// available height the way `HSplitView` does (each child gets only its own ideal height,
    /// vertically centered), which without an explicit `maxHeight: .infinity` on
    /// `SessionFilmstripView` left it short and mis-sized against `EditorView` beside it. A brief
    /// theory that nesting this `HSplitView` around `EditorView`'s own inner one (for
    /// `StagesSidebarView`/preview/`EditorSidebarView`) was inflating the window's minimum width
    /// turned out to be wrong — measuring the actual window (`osascript`, forcing a resize and
    /// reading it back) showed the exact same ~2759pt floor with a plain `HStack` in place of this
    /// `HSplitView`, so nesting wasn't the culprit. The real one was `ColorBalanceBarView`'s bottom
    /// bar: seat its own doc comment on `body` for why its sections' `.fixedSize(horizontal: true)`
    /// made *that* bar's full natural width an unconditional floor under the whole window,
    /// regardless of anything here — fixed there (wrapped in a horizontal `ScrollView`), not here.
    @ViewBuilder
    private var detailContent: some View {
        if let editingAsset = detailStore.editingAsset {
            HSplitView {
                SessionFilmstripView(asset: editingAsset, store: detailStore, onSelectAsset: openEditor)
                EditorView(asset: editingAsset, onSelectAsset: openEditor)
                    .id(editingAsset.id)
            }
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
    /// `Group` in `body` for why that's what makes the Mode switcher persistent. Import/Organize/Sort/
    /// Culling View only make sense for the grid (they act on `allAssets`/`selection`), so those stay
    /// gated behind `editingAsset == nil`. The rating/flag/file-type filters are unconditional —
    /// `SessionFilmstripView` respects them too (see `DetailStore.passesActiveFilters`), so they need
    /// to stay reachable while editing, not just from the grid. The Mode switcher itself is also
    /// unconditional and, notably, `.navigation`-placed like everything else here rather than
    /// centered `.principal` — it's the one control meant to survive the grid/editor swap, and (now
    /// that `onChange(of: detailStore.editingAsset)` above keeps it in sync) it's also how the editor
    /// closes: clicking "Sessions" while editing is what used to be a separate "Done" button. Split
    /// out between two separate `if detailStore.editingAsset == nil` blocks in the property below —
    /// not gated itself, but still landing in the same visual position relative to what's on either
    /// side of it whether or not those two blocks' content is showing.
    /// A thin vertical separator between toolbar item clusters — a plain `Divider()` renders along
    /// the *wrong* axis in a `ToolbarItem` (it adapts to a surrounding stack's orientation, but a
    /// `ToolbarItem` isn't one, so it defaults to a horizontal line instead of the vertical
    /// separator this toolbar's horizontal layout needs); a fixed-size filled `Rectangle` sidesteps
    /// that. Used at every cluster boundary in `toolbarContent` below rather than defined once — a
    /// computed property instead of a stored value since `ToolbarItem` needs a fresh `View` at each
    /// call site, not a shared instance.
    private var toolbarDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.35))
            .frame(width: 1, height: 18)
    }

    /// A plain blank gap, no line — used at three seams that all want a distinctly wider break than
    /// the rest of this toolbar's tight vertical-divider spacing: between the wordmark and the
    /// rating/flag/file-type filter cluster beside it, between that filter cluster and the action
    /// cluster (Stack/Scene) beside it, and between the Import button and the Mode switcher past it.
    private var toolbarWideSpacer: some View {
        Color.clear.frame(width: 96, height: 1)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // The very first `.navigation` item, so it's the true leading edge of the toolbar (right
        // after the sidebar-toggle button macOS adds automatically) — no longer sized to the
        // toolbar's regular caption-weight text/icons; back to reading as a wordmark in its own
        // right rather than blending into the controls beside it.
        ToolbarItem(placement: .navigation) {
            Image("CurvesWordmark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 28)
                .foregroundStyle(.primary)
                // At this larger size the wordmark's own vertical centering sits a few px lower
                // than the toolbar's other text/icon baselines — a pure visual nudge, not a layout
                // change, so `.offset` rather than padding (which would just shift the whole item).
                .offset(y: -3)
        }
        ToolbarItem(placement: .navigation) {
            toolbarWideSpacer
        }
        // `.navigation`, not `.primaryAction` — on macOS that's the one placement that lands at the
        // toolbar's true far left (right after the sidebar-toggle button macOS adds automatically),
        // rather than merely first among the `.primaryAction` cluster. Unconditional
        // (unlike Import/Stack-Scene/Sort/Culling View further down, which only mean anything against the
        // grid's own `allAssets`/`selection`) — `SessionFilmstripView`'s `filmstripItems` also
        // filters by these (see `DetailStore.passesActiveFilters`), so leaving them out while editing
        // would hide the only way to change what the filmstrip shows without first backing out to
        // the grid.
        ToolbarItem(placement: .navigation) {
            RatingFilterControl(store: detailStore)
        }
        ToolbarItem(placement: .navigation) {
            toolbarDivider
        }
        ToolbarItem(placement: .navigation) {
            FlagFilterControl(store: detailStore)
        }
        ToolbarItem(placement: .navigation) {
            toolbarDivider
        }
        // Grouped into one `ToolbarItemGroup` rather than two more top-level `ToolbarItem`/`if`
        // statements here — `@ToolbarContentBuilder`, like `@ViewBuilder`, only composes up to 10
        // top-level children before failing to type-check (`error: extra argument in call`, thrown
        // from an unrelated-looking line); this keeps `toolbarContent` under that ceiling without
        // changing anything about how either control actually renders. "Sync" is grid-only (scans/
        // mutates `allAssets`, same reasoning as `StackSceneControl` below) but placed directly
        // beside the RAW/JPG filter rather than down with that cluster — it's conceptually about
        // *what these files are*, same as the filter beside it, not a selection-driven organize
        // action.
        ToolbarItemGroup(placement: .navigation) {
            FileTypeFilterControl(store: detailStore)
            if detailStore.editingAsset == nil {
                Button {
                    syncRawJPGPairs()
                } label: {
                    Text("Sync")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .help("Group every matching RAW+JPG pair in the library into one stacked item")
            }
        }
        // Unconditional, unlike the rest of this gap's neighbors — while editing, everything from
        // `StackSceneControl` through the Import button below is gated away, and without this the
        // Mode switcher (also unconditional, at the very end) would sit crowded directly against
        // "JPG" instead of keeping the same breathing room it has in the grid.
        ToolbarItem(placement: .navigation) {
            toolbarWideSpacer
        }
        // Import/Stack-Scene/Sort/Culling View only mean anything against the grid's own
        // `allAssets`/`selection`, so they stay gated behind `editingAsset == nil` — but they've
        // joined the filters in `.navigation` placement too (same far-left reasoning as those).
        if detailStore.editingAsset == nil {
            ToolbarItem(placement: .navigation) {
                StackSceneControl(
                    store: detailStore,
                    onGroupStack: groupSelectedIntoStack,
                    onNewScene: {
                        detailStore.addSelectionToNewScene = true
                        detailStore.newSceneName = ""
                        detailStore.newSceneSession = detailStore.commonSessionForSelection
                        detailStore.isShowingNewSceneAlert = true
                    }
                )
            }
            ToolbarItem(placement: .navigation) {
                toolbarDivider
            }
            ToolbarItem(placement: .navigation) {
                Menu {
                    // Flat `Button`s, not a `Picker` — a `Picker` nested inside a `Menu` renders as
                    // its *own* nested submenu (labeled "Sort", same as the label below it) rather
                    // than flattening its options directly into the parent, so opening "Sort" here
                    // used to reveal a single "Sort ▸" row needing a second click before any actual
                    // option showed — the same "double dropdown" shape `StackSceneControl`'s "Scene"
                    // menu avoids the same way, with a checkmark standing in for the Picker's own
                    // selection indicator.
                    ForEach(SortOption.allCases) { option in
                        Button {
                            detailStore.sortOption = option
                        } label: {
                            if option == detailStore.sortOption {
                                Label(option.rawValue, systemImage: "checkmark")
                            } else {
                                Text(option.rawValue)
                            }
                        }
                    }
                } label: {
                    Text("Sort")
                        .font(.caption.weight(.semibold))
                }
                // `.menuStyle(.borderlessButton)` drops the pill/box background a toolbar `Menu`
                // otherwise draws around its label — every other flat-text control beside this one
                // (RAW/JPG, Stack/Scene) has no such box, so this brings Sort in line with them.
                // `.controlSize(.small)`: a toolbar `Menu` otherwise reserves more padding around its
                // label than a plain `Button` does (the same `.buttonStyle(.plain)` "Stack"/"Scene"
                // use), which read as Sort sitting a size class up from its neighbors even with
                // identical font/weight — this brings the two down to matching size and alignment.
                // `.tint(.secondary)`, not `.primary` — a toolbar `Menu` picks up the accent/tint
                // color automatically, ignoring `.foregroundStyle` on its label, so this is the only
                // way to override it; `.secondary` matches "Stack"/"Scene"'s resting (unselected)
                // brightness beside it, since Sort has no "active" state of its own to ever go
                // brighter for the way Stack/Scene do once something's selected.
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .tint(.secondary)
            }
            ToolbarItem(placement: .navigation) {
                toolbarDivider
            }
            ToolbarItem(placement: .navigation) {
                Toggle(isOn: $detailStore.isCullingViewActive) {
                    // The standard "enter full screen" glyph (same one macOS/Apple apps use for
                    // their own fullscreen toggle) rather than a bespoke icon — reads at a glance
                    // as "go fullscreen" without needing the tooltip.
                    Label("Culling View", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .toggleStyle(.button)
                .help("Culling View — review and grade one photo at a time")
            }
            ToolbarItem(placement: .navigation) {
                toolbarDivider
            }
            ToolbarItem(placement: .navigation) {
                GridZoomControl(store: detailStore)
            }
            ToolbarItem(placement: .navigation) {
                toolbarDivider
            }
            // Not up front with the rest — it's the one action here that isn't about the current
            // selection/filter, so it reads more like a standalone "add to the library" affordance
            // than part of the filter/organize group beside it.
            ToolbarItem(placement: .navigation) {
                Button {
                    importFolder()
                } label: {
                    Label("Import Folder", systemImage: "plus")
                }
            }
            ToolbarItem(placement: .navigation) {
                toolbarWideSpacer
            }
        }
        // Unconditional, unlike everything else in this cluster — it's the one control here meant
        // to survive the grid/editor swap: `.onChange(of: detailStore.editingAsset)` keeps it in
        // sync, and clicking "Sessions" while editing is what closes the editor (there's no separate
        // "Done" button). Placed after the `if` above rather than gated with it, so it stays visible
        // in the same trailing position whether or not that block's own content is showing.
        // Grouped with the Mode switcher (not its own top-level item) to stay under
        // `@ToolbarContentBuilder`'s 10-child ceiling — see the Sync group's comment above.
        ToolbarItemGroup(placement: .navigation) {
            DeveloperModeToolbarToggle()
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

        // A `Session` maps 1:1 to a folder (see `Session`'s doc comment) — if this exact folder
        // already has one, importing into it (e.g. re-running import after adding more files to the
        // card) resumes silently rather than asking the user to pick from a list that, by
        // construction, can never contain a valid *different* choice for this folder.
        if let existing = sessions.first(where: { $0.resolvedFolderURL().path == url.path }) {
            performImport(files: files, session: existing)
            return
        }

        pendingImportFiles = files
        pendingImportFolderURL = url
        newSessionName = ""
        isShowingSessionPicker = true
    }

    private func performImport(files: [URL], session: Session) {
        let importer = LibraryImporter()
        do {
            let imported = try importer.importFiles(files, into: modelContext, session: session)
            // Per newly-imported photo: if a `.curve` sidecar already sits beside the file (e.g.
            // re-importing a folder that has sidecars from a previous run of this app, or from
            // another machine), real edit history wins — adopt it. Otherwise this is a genuinely
            // new file: apply the "Default Stage" preset, if any (see
            // `StageFieldSnapshot.applyDefaultIfAvailable(to:context:)`, not done inside
            // `LibraryImporter` itself since that lives in the PhotoCatalog package, which has no
            // visibility into `Preset`/`StageFieldSnapshot`), then write a fresh baseline sidecar so
            // this photo has one from the moment it enters the library.
            //
            // Only the asset's own base params + single stage are adopted here — recreating custom
            // stages/version history needs to insert new `Stage`/`AssetVersion` rows into
            // `modelContext`, which is a full library rebuild's job (see the sidecar-persistence
            // plan's read/rebuild phase), not a normal re-import's.
            for asset in imported {
                if let data = try? Data(contentsOf: asset.sidecarURL()),
                   let sidecar = try? JSONDecoder().decode(CurveSidecar.self, from: data) {
                    sidecar.baseFields.apply(to: asset)
                    asset.ratingRaw = sidecar.rating
                    asset.flagRaw = sidecar.flagRaw
                    asset.colorLabelRaw = sidecar.colorLabelRaw
                    sidecar.singleStage.apply(to: asset.singleStage)
                } else {
                    StageFieldSnapshot.applyDefaultIfAvailable(to: asset, context: modelContext)
                    persistSidecars(for: asset)
                }
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
        groupIntoStack(selected)
        try? modelContext.save()
        detailStore.refreshTrigger += 1
        refreshFilteredAssets()
    }

    /// Core mechanics shared by `groupSelectedIntoStack()` and `syncRawJPGPairs()` — moves every
    /// asset in `assets` into one brand-new `PhotoStack`, unwinding (and deleting, if left empty)
    /// any stack it was already in. Doesn't save/refresh itself — `syncRawJPGPairs()` processes
    /// many groups in one pass and batches those into a single save/refresh at the end instead of
    /// paying the cost once per group.
    private func groupIntoStack(_ assets: [PhotoAsset]) {
        var touchedStacks: [PhotoStack: Session] = [:]
        for asset in assets {
            if let old = asset.stack {
                if let session = asset.session { touchedStacks[old] = session }
                asset.stack = nil
            }
        }
        let newStack = PhotoStack()
        modelContext.insert(newStack)
        for asset in assets {
            asset.stack = newStack
        }
        for (old, session) in touchedStacks where (old.photos?.isEmpty ?? true) {
            deleteSidecarManifest(for: old, session: session)
            modelContext.delete(old)
        }
        // Every unstacked-then-restacked asset's `.curve` needs its `stackID` pointer refreshed,
        // and the new stack needs its `.stack` manifest written at least once so it exists on disk
        // even before any value-level edit ever touches its shared stage.
        persistSidecars(for: assets)
    }

    /// The toolbar's "Sync" button — scans the *whole* library (not just what's currently filtered/
    /// visible) for RAW+JPG pairs sharing a base filename, and groups each one into a stack via
    /// `groupIntoStack(_:)`, the same mechanism "Group Selected into Stack" uses. Scoped to matches
    /// within the same `Session` as a safety bound — two unrelated files that happen to share a name
    /// in different sessions shouldn't get merged. Skips any group that's already fully stacked
    /// together, so re-running this after it's already synced everything is a no-op.
    private func syncRawJPGPairs() {
        var groups: [String: [PhotoAsset]] = [:]
        for asset in allAssets {
            guard let sessionID = asset.session?.id else { continue }
            groups["\(sessionID)|\(asset.baseFileName.lowercased())", default: []].append(asset)
        }
        var didChange = false
        for group in groups.values {
            let raws = group.filter { RawFileType.extensions.contains($0.fileExtension.lowercased()) }
            let jpgs = group.filter { ["jpg", "jpeg"].contains($0.fileExtension.lowercased()) }
            guard !raws.isEmpty, !jpgs.isEmpty else { continue }
            let pair = raws + jpgs
            let stackIDs = Set(pair.map { $0.stack?.id })
            guard stackIDs.count > 1 || stackIDs.first! == nil else { continue }
            groupIntoStack(pair)
            didChange = true
        }
        guard didChange else { return }
        try? modelContext.save()
        detailStore.refreshTrigger += 1
        refreshFilteredAssets()
    }

    private func unstackSelected() {
        let selected = allAssets.filter { detailStore.selection.contains($0.id) }
        var touchedStacks: [PhotoStack: Session] = [:]
        for asset in selected {
            if let stack = asset.stack, let session = asset.session {
                touchedStacks[stack] = session
            }
        }
        var formerMembers: [PhotoAsset] = []
        for (stack, session) in touchedStacks {
            let members = stack.photos ?? []
            formerMembers.append(contentsOf: members)
            for member in members {
                member.stack = nil
            }
            deleteSidecarManifest(for: stack, session: session)
            modelContext.delete(stack)
        }
        try? modelContext.save()
        persistSidecars(for: formerMembers)
        detailStore.refreshTrigger += 1
        refreshFilteredAssets()
    }

    private func addSelected(to scene: PhotoScene) {
        let selected = allAssets.filter { detailStore.selection.contains($0.id) }
        for asset in selected {
            asset.scene = scene
        }
        try? modelContext.save()
        persistSidecars(for: selected)
        detailStore.refreshTrigger += 1
        refreshFilteredAssets()
    }

    private func removeSelectedFromCurrentScene() {
        guard let selectedScene else { return }
        let selected = allAssets.filter { detailStore.selection.contains($0.id) && $0.scene?.id == selectedScene.id }
        for asset in selected {
            asset.scene = nil
        }
        try? modelContext.save()
        persistSidecars(for: selected)
        if let session = selectedScene.session {
            persistSidecar(for: selectedScene, session: session)
        }
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
        var assignedMembers: [PhotoAsset] = []
        if !detailStore.pendingSceneAssetIDs.isEmpty {
            let targeted = allAssets.filter { detailStore.pendingSceneAssetIDs.contains($0.id) }
            for asset in targeted {
                asset.scene = scene
            }
            assignedMembers = targeted
            detailStore.pendingSceneAssetIDs = []
        } else if addSelection {
            let selected = allAssets.filter { detailStore.selection.contains($0.id) }
            for asset in selected {
                asset.scene = scene
            }
            assignedMembers = selected
        }
        try? modelContext.save()
        persistSidecars(for: assignedMembers)
        persistSidecar(for: scene, session: session)
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
        persistSidecars(for: selected)
        persistSidecar(for: scene, session: session)
        detailStore.quickSceneName = ""
        detailStore.isShowingScenePicker = false
        detailStore.refreshTrigger += 1
        refreshFilteredAssets()
    }

    private func deleteScene(_ scene: PhotoScene) {
        if selectedScene?.id == scene.id {
            selectedScene = nil
        }
        // Captured before the delete: `.nullify` clears every member's `asset.scene` and the
        // scene's own `session` the instant the row is gone, so both are needed now to update the
        // former members' `.curve` files and remove the manifest afterward.
        let formerMembers = scene.photos ?? []
        let session = scene.session
        modelContext.delete(scene)
        try? modelContext.save()
        persistSidecars(for: formerMembers)
        if let session {
            deleteSidecarManifest(for: scene, session: session)
        }
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
