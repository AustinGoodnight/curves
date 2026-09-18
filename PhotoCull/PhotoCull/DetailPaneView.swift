import SwiftUI
import SwiftData
import PhotoCatalog

/// Everything about the currently-browsed/edited photo set that changes on *every click or arrow
/// key press* — selection, the open editor, filters, sort, and the alerts/sheets those drive.
///
/// This used to all be plain `@State` directly on `ContentView`. That was the real cause of the
/// "selecting a photo is laggy" bug — `@State` invalidation always invalidates the *entire* view
/// that declares it, not just the part that visually changed. With `selection` living on
/// `ContentView`, every single click forced `ContentView.body` to re-run in full, which meant
/// re-diffing/reconciling the *whole* `NavigationSplitView` — sidebar, split-view layout, and
/// macOS window toolbar — on every click, measured at ~180-200ms fixed cost *regardless of
/// library size*.
///
/// The fix: pull all of this into an `@Observable` reference type, owned by `ContentView` via
/// `@State private var detailStore = DetailStore()` (so the instance itself is stable across
/// `ContentView.body` re-runs) and handed to child views to read/write. Swift's Observation
/// framework tracks dependencies per property *read*, not per object reference — as long as
/// `ContentView.body` itself never reads a `detailStore.x` property's *value* (only forwards
/// `Binding`s to it, or the object reference itself, to children), changing `selection` only
/// invalidates whichever view's body actually read `selection` last.
///
/// **A second, harder-to-see trap lives one level up from this, in `ContentView.body` itself: see
/// its doc comment on why `@Query var allAssets` must never be read — not even just to pass as a
/// value parameter — anywhere that isn't gated behind `editingAsset == nil`.** That one cost a
/// full extra investigation to find: `.equatable()`/state-extraction here were never the problem;
/// an *unconditional* `allAssets` read elsewhere in `ContentView.body` was.
@Observable
final class DetailStore {
    var selection: Set<UUID> = []
    var editingAsset: PhotoAsset?
    var gridMode: GridMode = .sessions
    /// Toggled from the toolbar's "Culling View" button, like a full-screen toggle — swaps the
    /// grid for `CullingPresentationView`'s one-photo-at-a-time review screen. Low-frequency (one
    /// user click/`Esc` per session), so it's fine to live here and be read directly in
    /// `ContentView.body`/`toolbarContent`, unlike `selection`/`editingAsset`.
    var isCullingViewActive: Bool = false
    var ratingFilter: Int = 0
    var flagFilter: FlagState?
    var fileTypeFilter: FileTypeFilter = .all
    var sortOption: SortOption = .captureDateDesc
    var refreshTrigger = 0
    /// Which stacks are shown expanded (all members visible) vs collapsed (one cover cell) — used
    /// only by `rebuildDisplayItems()`. Not local `@State` on `CullingGridView` — it needs to live
    /// where the (untracked) rebuild function lives.
    var expandedStacks: Set<UUID> = []

    /// The session grid's column count — one of `Self.gridColumnSteps`, never a value computed from
    /// window/container width. See `CullingGridView.columnCount`'s doc comment for why this stays a
    /// small, fixed set of prefixed steps rather than continuous `GeometryReader`-driven sizing:
    /// that measuring pass is what caused this project's worst click-lag regression (CLAUDE.md).
    /// Low-frequency (one user zoom action at a time), same as `isCullingViewActive`, so it's fine
    /// to live here and be read directly by `GridPane`/`ContentView` rather than needing the
    /// `.onChange`-driven caching `selection`/`filteredAssets` require.
    var gridColumnCount: Int = 8

    /// Ordered from most zoomed-out (most, smallest columns) to most zoomed-in (fewest, largest
    /// columns) — `zoomInGrid`/`zoomOutGrid` step one entry at a time through this list.
    static let gridColumnSteps = [19, 16, 13, 10, 8, 6, 5, 4, 3]

    var canZoomInGrid: Bool {
        guard let index = Self.gridColumnSteps.firstIndex(of: gridColumnCount) else { return true }
        return index < Self.gridColumnSteps.count - 1
    }

    var canZoomOutGrid: Bool {
        guard let index = Self.gridColumnSteps.firstIndex(of: gridColumnCount) else { return true }
        return index > 0
    }

    func zoomInGrid() {
        guard let index = Self.gridColumnSteps.firstIndex(of: gridColumnCount), index < Self.gridColumnSteps.count - 1 else { return }
        gridColumnCount = Self.gridColumnSteps[index + 1]
    }

    func zoomOutGrid() {
        guard let index = Self.gridColumnSteps.firstIndex(of: gridColumnCount), index > 0 else { return }
        gridColumnCount = Self.gridColumnSteps[index - 1]
    }

    var isShowingNewSceneAlert = false
    var newSceneName = ""
    var addSelectionToNewScene = false
    var newSceneSession: Session?
    var isShowingScenePicker = false
    var quickSceneName = ""
    /// Set by `ContentView.beginSceneCreation(for:)` (the culling view's "S" scene-mark shortcut)
    /// right before it opens the same "New Scene" alert used everywhere else. Non-empty takes
    /// priority over `addSelectionToNewScene`/`selection` in `ContentView.createScene(named:addSelection:)`
    /// — a specific, already-computed asset range rather than "whatever's currently selected".
    var pendingSceneAssetIDs: Set<UUID> = []

    /// The single session shared by every currently-selected asset, or `nil` if the selection is
    /// empty or spans more than one session — see `refreshSelectionDerivedState`.
    var commonSessionForSelection: Session?
    var scenesInCommonSession: [PhotoScene] = []

    /// Cached, not computed — call only from `ContentView`'s `.onChange(of: selection)`/
    /// `.onChange(of: editingAsset)`.
    func refreshSelectionDerivedState(allAssets: [PhotoAsset], scenes: [PhotoScene]) {
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

    /// The rating/flag/file-type filters, independent of the scene/session scoping
    /// `refreshFilteredAssets` also applies — shared with `SessionFilmstripView`, which is scoped to
    /// the open photo's session rather than the active scene/session selection but should still
    /// respect the same rating/flag/file-type filters as the grid.
    func passesActiveFilters(_ asset: PhotoAsset) -> Bool {
        if ratingFilter > 0, asset.rating < ratingFilter { return false }
        if let flagFilter, asset.flag != flagFilter { return false }
        switch fileTypeFilter {
        case .all:
            return true
        case .raw:
            return RawFileType.extensions.contains(asset.fileExtension.lowercased())
        case .jpeg:
            return ["jpg", "jpeg"].contains(asset.fileExtension.lowercased())
        }
    }

    /// Cached, not computed. Callable from `ContentView`'s own mutation functions, since those
    /// mutate `allAssets` in ways that can change the answer.
    func refreshFilteredAssets(allAssets: [PhotoAsset], selectedScene: PhotoScene?, selectedSession: Session?) {
        var result = allAssets
        if let selectedScene {
            result = result.filter { $0.scene?.id == selectedScene.id }
        } else if let selectedSession {
            result = result.filter { $0.session?.id == selectedSession.id }
        }
        result = result.filter { passesActiveFilters($0) }
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
        filteredAssets = result
        rebuildDisplayItems()
    }

    var filteredAssets: [PhotoAsset] = []

    /// The grid's actual render list — one entry per visible cell (a single photo, a collapsed
    /// stack cover, or one expanded stack member). Built here, in an ordinary (non-`View`,
    /// non-tracked) method, rather than as a computed property read inside `CullingGridView.body`.
    /// Building this touches `.stack`/`.id`/`.photos` on every asset in the current filter, and
    /// since `@Model` types participate in Swift's Observation framework, doing that *inside a
    /// tracked `body`* would register `CullingGridView` as a dependent of every one of those
    /// objects' properties — thousands of dependency edges on a real library, rebuilt on every
    /// render. Building the list here means `CullingGridView` depends on exactly one thing — this
    /// array's value — nothing more.
    var displayItems: [DisplayItem] = []

    func rebuildDisplayItems() {
        let assetIDs = Set(filteredAssets.map(\.id))
        var seenStacks = Set<UUID>()
        var items: [DisplayItem] = []
        for asset in filteredAssets {
            if let stack = asset.stack {
                guard !seenStacks.contains(stack.id) else { continue }
                seenStacks.insert(stack.id)
                let visibleMembers = (stack.photos ?? [])
                    .filter { assetIDs.contains($0.id) }
                    .sorted { ($0.captureDate ?? $0.importDate) < ($1.captureDate ?? $1.importDate) }
                guard let cover = visibleMembers.first else { continue }
                if expandedStacks.contains(stack.id) {
                    let total = visibleMembers.count
                    for (index, member) in visibleMembers.enumerated() {
                        items.append(.stackMember(member, position: index + 1, total: total))
                    }
                } else {
                    items.append(.stackCover(stack, cover: cover, count: visibleMembers.count))
                }
            } else {
                items.append(.single(asset))
            }
        }
        displayItems = items
    }

    func setStackExpanded(_ stackID: UUID, expanded: Bool) {
        if expanded {
            expandedStacks.insert(stackID)
        } else {
            expandedStacks.remove(stackID)
        }
        rebuildDisplayItems()
    }
}

enum DisplayItem: Identifiable {
    case single(PhotoAsset)
    case stackCover(PhotoStack, cover: PhotoAsset, count: Int)
    case stackMember(PhotoAsset, position: Int, total: Int)

    var id: String {
        switch self {
        case .single(let asset): return "single-\(asset.id)"
        case .stackCover(let stack, _, _): return "cover-\(stack.id)"
        case .stackMember(let asset, _, _): return "member-\(asset.id)"
        }
    }
}

/// `RawFileType.extensions` (from `PhotoCatalog`) is the source of truth for what counts as RAW;
/// `.jpeg` here matches both `jpg`/`jpeg` extensions.
enum FileTypeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case raw = "RAW"
    case jpeg = "JPEG"
    var id: String { rawValue }
}

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

/// Just the grid itself (plus its "no photos"/"no matches" overlay) — deliberately *not* the
/// `NavigationStack`/toolbar/`.navigationDestination` that wraps it in `ContentView`, and
/// deliberately constructed *only* when `ContentView.body` has already confirmed
/// `editingAsset == nil` (see that gating at this view's call site in `ContentView.body`, not
/// inside this view's own `body` — that distinction is load-bearing, see `ContentView`'s doc
/// comment). `Equatable`, comparing `allAssets` (SwiftData's identity-based equality — same
/// objects, not field values) and `store`'s reference identity, is what lets `.equatable()` at the
/// call site skip re-invoking this `body` when nothing it actually reads has changed — e.g. when
/// `ContentView.body` reruns for reasons that have nothing to do with the grid.
struct GridPane: View, Equatable {
    let allAssets: [PhotoAsset]
    /// Not used for rendering — `store.filteredAssets`/`store.displayItems` are already filtered
    /// by these — only to rebuild correctly (respecting the active scene/session filter) from
    /// `onDataChanged`, when a rating/flag keyboard shortcut mutates an asset directly.
    let selectedScene: PhotoScene?
    let selectedSession: Session?
    @Bindable var store: DetailStore
    var onGroupStack: () -> Void
    var onUnstack: () -> Void
    var onOpenEditor: (PhotoAsset) -> Void

    static func == (lhs: GridPane, rhs: GridPane) -> Bool {
        lhs.allAssets == rhs.allAssets && lhs.selectedScene == rhs.selectedScene
            && lhs.selectedSession == rhs.selectedSession && lhs.store === rhs.store
    }

    var body: some View {
        CullingGridView(
            assets: store.filteredAssets,
            displayItems: store.displayItems,
            selection: $store.selection,
            columnCount: store.gridColumnCount,
            isEditMode: store.gridMode == .edit,
            onGroupStack: onGroupStack,
            onUnstack: onUnstack,
            onOpenEditor: onOpenEditor,
            onDataChanged: { store.refreshFilteredAssets(allAssets: allAssets, selectedScene: selectedScene, selectedSession: selectedSession) },
            onToggleStack: { id, expand in store.setStackExpanded(id, expanded: expand) }
        )
        .overlay {
            if allAssets.isEmpty {
                ContentUnavailableView(
                    "No Photos",
                    systemImage: "photo.on.rectangle.angled",
                    description: Text("Import a folder of photos to get started.")
                )
            } else if store.filteredAssets.isEmpty {
                ContentUnavailableView(
                    "No Matches",
                    systemImage: "line.3.horizontal.decrease.circle",
                    description: Text("No photos match the current filter.")
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !allAssets.isEmpty {
                ExportBarView(store: store)
            }
        }
    }
}

/// Steps `DetailStore.gridColumnCount` through `DetailStore.gridColumnSteps` — fewer columns means
/// larger photos ("zoomed in"), more columns means smaller photos ("zoomed out"). Mirrors ⌘+/⌘-,
/// wired up as hidden buttons in `ContentView.rootView`. Pulled out as its own `View` for the same
/// reason as `RatingFilterControl` beside it: reading `store.gridColumnCount`/`canZoomInGrid`/
/// `canZoomOutGrid` as values means only this small view's `body` re-runs when the zoom level
/// changes, not `ContentView`'s.
struct GridZoomControl: View {
    @Bindable var store: DetailStore

    var body: some View {
        HStack(spacing: 6) {
            Button {
                store.zoomOutGrid()
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .disabled(!store.canZoomOutGrid)
            .help("Zoom out (more, smaller photos)")

            Button {
                store.zoomInGrid()
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.plain)
            .disabled(!store.canZoomInGrid)
            .help("Zoom in (fewer, larger photos)")
        }
        .foregroundStyle(Color.secondary)
    }
}

/// Pulled out of `ContentView.toolbarContent` on purpose — this
/// reads `store.ratingFilter` as a value, so as its own `View` type only *this* small view's
/// `body` re-runs when the rating filter changes. Five stars, shown inline in the toolbar rather
/// than behind a menu, set a *minimum* rating (Lightroom-style): tapping star N shows N+ stars;
/// tapping the already-active star again clears the filter back to "All Ratings".
struct RatingFilterControl: View {
    @Bindable var store: DetailStore

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    store.ratingFilter = (store.ratingFilter == star) ? 0 : star
                } label: {
                    Image(systemName: star <= store.ratingFilter ? "star.fill" : "star")
                }
                .buttonStyle(.plain)
                .foregroundStyle(star <= store.ratingFilter ? Color.yellow : Color.secondary)
            }
        }
        // The star glyphs sit slightly high relative to the toolbar's other text/icon controls —
        // a few px of bottom padding nudges this row down so it reads as vertically inline with
        // its neighbors instead of floating a bit above them.
        .padding(.bottom, 3)
        .help("Filter by minimum rating")
    }
}

/// Pulled out of `ContentView.toolbarContent` on purpose, same reasoning as `RatingFilterControl`
/// — reads `store.flagFilter` as a value. Three toggle buttons shown inline rather than behind a
/// menu; tapping the active flag again clears the filter back to "All Flags".
struct FlagFilterControl: View {
    @Bindable var store: DetailStore

    var body: some View {
        HStack(spacing: 6) {
            flagButton(.pick, systemImage: "checkmark", color: .green, help: "Picked")
            flagButton(.reject, systemImage: "xmark", color: .red, help: "Rejected")
            flagButton(.none, systemImage: "circle", color: .secondary, help: "Unflagged")
        }
    }

    private func flagButton(_ flag: FlagState, systemImage: String, color: Color, help: String) -> some View {
        let isSelected = store.flagFilter == flag
        return Button {
            store.flagFilter = isSelected ? nil : flag
        } label: {
            Image(systemName: systemImage)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? color : Color.secondary)
        .help(help)
    }
}

/// Pulled out of `ContentView.toolbarContent` on purpose, same reasoning as `RatingFilterControl`
/// — reads `store.fileTypeFilter` as a value. Two toggle buttons shown inline, same "tap the active
/// one again to clear back to All" convention as `FlagFilterControl`, rather than a `Menu`/`Picker`
/// dropdown — RAW/JPG read directly off the toolbar instead of needing a click to reveal them, and
/// it keeps this control visually consistent with `RatingFilterControl`/`FlagFilterControl` beside
/// it rather than picking up a `Menu`'s default accent-tinted icon (see `uiColors.accentColor` used
/// for the *selected* state below, same as everywhere else in the app that marks a selection).
struct FileTypeFilterControl: View {
    @Bindable var store: DetailStore
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        HStack(spacing: 6) {
            fileTypeButton(.raw, label: "RAW")
            fileTypeButton(.jpeg, label: "JPG")
        }
    }

    private func fileTypeButton(_ type: FileTypeFilter, label: String) -> some View {
        let isSelected = store.fileTypeFilter == type
        return Button {
            store.fileTypeFilter = isSelected ? .all : type
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSelected ? uiColors.accentColor : Color.secondary)
        .help("Show only \(label) photos")
    }
}

/// Pulled out of `ContentView.toolbarContent` on purpose, same reasoning as `RatingFilterControl` —
/// reads `store.gridMode` as a value. Replaces a stock `Picker(.segmented)` with the same "plain
/// text, filled pill when selected" tab language `ColorBalanceBarView`'s `colorZonesChannelSwitcher`/
/// `channelTab` use elsewhere in the app, so the one native-chrome control left in the toolbar
/// reads as part of the same design system instead of stock macOS segmented-control styling.
/// Unconditional at its call site — the one control that survives the grid/editor swap — and, since
/// `ContentView`'s `onChange(of: detailStore.editingAsset)` keeps `gridMode` synced to whether the
/// editor is open, tapping "Sessions" while editing is what closes the editor now (no separate
/// "Done" button).
struct ModeSwitcherControl: View {
    @Bindable var store: DetailStore

    /// One flat text button, not a two-tab switcher — labeled with the *destination*, not the
    /// current mode: "Edit" while in Sessions (tap to open the editor for the current selection),
    /// "Session" while in Edit (tap to close it). Reads as one more plain-text action alongside
    /// RAW/JPG, Stack/Scene, and Sort, rather than a distinct piece of chrome.
    var body: some View {
        Button {
            store.gridMode = store.gridMode == .sessions ? .edit : .sessions
        } label: {
            Text(store.gridMode == .sessions ? "Edit" : "Session")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.secondary)
        }
        .buttonStyle(.plain)
        // There's no visual box whose own padding would naturally hold this off the toolbar's
        // trailing edge — it renders flush against the window's edge otherwise, since this is the
        // last item in `ContentView.toolbarContent`.
        .padding(.trailing, 64)
    }
}

/// Pulled out of `ContentView.toolbarContent` on purpose, same reasoning as `RatingFilterControl`
/// — reads `store.selection` as a value. "Stack"/"Scene" are one-shot actions, not toggles like
/// RAW/JPG, but styled identically (same per-button helper shape, `.buttonStyle(.plain)`, `.caption`
/// weight-semibold text, `HStack(spacing: 6)`) for visual consistency across the toolbar's flat text
/// controls — the only difference is which state each button's dim/bright color reflects (an
/// enabled/disabled action here, a selected/unselected filter there).
///
/// Both skip the "which one?" step a `Menu` would otherwise need: "Stack" always groups the current
/// selection into a *new* stack (never "which stack"), and "Scene" always creates a *new* scene from
/// the selection (`onNewScene`, the same action `ContentView`'s "New Scene…" alert already drives) —
/// never a picker over existing scenes. Adding to an *existing* scene still has its own path
/// (⌘S → `ScenePickerSheet`, see `ContentView`'s hidden "Add Selected to Scene" button), so nothing
/// here is lost, just moved out of this cluster.
struct StackSceneControl: View {
    @Bindable var store: DetailStore
    var onGroupStack: () -> Void
    var onNewScene: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            actionButton("Stack", enabled: store.selection.count >= 2, help: "Group Selected into Stack (G)", action: onGroupStack)
            // Same thin-vertical-bar treatment as `ContentView.toolbarDivider`, inlined here since
            // this pair sits inside one `ToolbarItem`, not two separate ones a divider could go
            // between.
            Rectangle()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 1, height: 14)
            actionButton("Scene", enabled: !store.selection.isEmpty, help: "New Scene from Selection…", action: onNewScene)
        }
    }

    /// `enabled` gates the tap from *inside* the action closure rather than via SwiftUI's
    /// `.disabled(_:)` — that modifier layers its own automatic dimming on top of whatever
    /// `.foregroundStyle` is already set, which made the "not actionable" state noticeably darker
    /// than `FileTypeFilterControl`'s equivalent un-selected `Color.secondary` (never `.disabled()`
    /// itself) even though both nominally used the same color. Skipping `.disabled()` here keeps the
    /// two controls' resting colors pixel-identical.
    private func actionButton(_ label: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary)
        .help(help)
    }
}
