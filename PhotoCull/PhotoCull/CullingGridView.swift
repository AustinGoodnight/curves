import SwiftUI
import AppKit
import PhotoCatalog

struct CullingGridView: View {
    let assets: [PhotoAsset]
    /// Pre-built by `DetailStore.rebuildDisplayItems()` — deliberately **not** computed here. See
    /// `DetailStore`'s doc comment on that method: building this list touches `.stack`/`.id` on
    /// every asset, and doing that inside a tracked `View.body` (as this used to do, as a computed
    /// property read at the top of `body`) registers this view as an Observation dependent of
    /// *every one of those objects' properties* — on a 1708-asset library that's ~3000+ dependency
    /// edges rebuilt on every render, and meant *any* unrelated SwiftData background activity
    /// (autosave, relationship fault resolution) could re-trigger a full grid re-render with no
    /// user action involved. That's what was still causing a mysterious *second* full render
    /// ~150-190ms after every single click/arrow-key press, even after `selection`/`editingAsset`
    /// were already isolated into their own `DetailStore` (see `DetailPaneView.swift`) — this view
    /// itself was still re-deriving `displayItems` reactively. Building it in an ordinary
    /// (untracked) function instead, and handing this view only the *result*, means this view
    /// depends on exactly one thing: the `displayItems` array value itself.
    let displayItems: [DisplayItem]
    @Binding var selection: Set<UUID>
    /// "Sessions" mode (`false`): a click only selects — multi-select for rating/flagging/
    /// stacking/scene-assigning stays available, opening a photo needs the hover-revealed edit
    /// button or Return. "Edit" mode (`true`): a click selects *and* immediately opens the editor
    /// — the tradeoff is you give up multi-select in this mode in exchange for one click per photo
    /// to jump straight into editing; switch back to Sessions mode for anything selection-based.
    var isEditMode: Bool = false
    var onGroupStack: () -> Void = {}
    var onUnstack: () -> Void = {}
    var onOpenEditor: (PhotoAsset) -> Void = { _ in }
    /// Called after a rating/flag edit made via keyboard shortcut, since those mutate `PhotoAsset`
    /// properties directly from here rather than through one of `DetailPaneView`'s own mutation
    /// functions. `DetailStore` uses this to invalidate its cached `filteredAssets`/`displayItems`.
    var onDataChanged: () -> Void = {}
    /// Expand/collapse a stack cover — mutates `DetailStore.expandedStacks` and rebuilds
    /// `displayItems`. Not local `@State` here anymore, for the same reason `displayItems` itself
    /// isn't: it needs to live where the (untracked) rebuild function lives.
    var onToggleStack: (UUID, Bool) -> Void = { _, _ in }

    @State private var lastClickedID: UUID?
    /// Set only by `moveFocus` (keyboard arrow-key navigation), never by `handleClick` (mouse
    /// clicks) — a fixed-cost animated `scrollTo` on *every* click, regardless of library size,
    /// was what made selecting a photo feel slow even on a small library after the two data-
    /// scaling fixes above landed. A mouse click can only ever land on a cell that's already
    /// visible on screen, so there's never a reason to re-center the scroll view for one; that
    /// behavior only matters for keyboard navigation, which can move focus off-screen.
    @State private var scrollTarget: UUID?
    @Environment(ColorSchemeStore.self) private var uiColors
    /// Fixed rather than computed from the container width via `GeometryReader` — that measuring
    /// pass turned out to be the actual remaining cause of the large-library click/arrow-key lag
    /// (confirmed by temporarily removing it entirely): `GeometryReader` forces a full second
    /// layout pass of everything inside it — including the whole 1708-item `LazyVGrid` — roughly
    /// 150-200ms after the first, on every single state change, regardless of whether the
    /// container size actually changed. A fixed column count sidesteps that entirely at the cost
    /// of not reflowing when the window resizes.
    private let columnCount = 7
    @FocusState private var isFocused: Bool

    private let spacing: CGFloat = 12

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: max(columnCount, 1))
    }

    /// Only ever called from action closures (`.onAppear`, `handleClick`, `handleKeyPress`), never
    /// from `body` itself — see `displayItems`'s doc comment for why that distinction matters. This
    /// one's fine to keep as a computed property since nothing here reads it reactively.
    private var clickableIDsInOrder: [UUID] {
        displayItems.map { item in
            switch item {
            case .single(let asset): return asset.id
            case .stackCover(_, let cover, _): return cover.id
            case .stackMember(let asset, _, _): return asset.id
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: spacing) {
                    ForEach(Array(displayItems.enumerated()), id: \.element.id) { index, item in
                        cell(for: item, at: index, in: displayItems)
                    }
                }
                .padding(spacing)
            }
            .onChange(of: scrollTarget) { _, newValue in
                if let newValue {
                    withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
            .background(uiColors.workspaceBackground)
        }
        .onAppear {
            if selection.isEmpty, let first = clickableIDsInOrder.first {
                selection = [first]
                lastClickedID = first
            }
        }
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(action: handleKeyPress)
    }

    /// Which scene (if any) the item at `index` belongs to — used both directly and to compare a
    /// cell against its grid neighbors when building `sceneBorderInfo(at:in:)`. Takes the
    /// `displayItems` array as a parameter purely for symmetry with the rest of this file's
    /// per-cell helpers; reading `self.displayItems` directly here would be equally safe now that
    /// it's a stored `let`, not a computed property, but threading it through keeps the "per-cell
    /// helpers take their data as parameters" convention consistent.
    private func currentScene(at index: Int, in items: [DisplayItem]) -> PhotoScene? {
        guard items.indices.contains(index) else { return nil }
        switch items[index] {
        case .single(let asset): return asset.scene
        case .stackCover(_, let cover, _): return cover.scene
        case .stackMember(let asset, _, _): return asset.scene
        }
    }

    /// `true` when the cell one step `rowOffset`/`colOffset` away from `index` (by grid position,
    /// not flat-array position — needed so a diagonal check near the grid's own edge correctly
    /// comes back `false` instead of wrapping to the next/previous row) belongs to the same scene.
    private func sameSceneNeighbor(
        _ index: Int, rowOffset: Int, colOffset: Int, scene: PhotoScene, in items: [DisplayItem]
    ) -> Bool {
        let col = index % max(columnCount, 1) + colOffset
        let row = index / max(columnCount, 1) + rowOffset
        guard col >= 0, col < columnCount, row >= 0 else { return false }
        return currentScene(at: row * columnCount + col, in: items)?.id == scene.id
    }

    /// Every cell belonging to a scene gets `PhotoThumbnailCell`'s colored mat behind its photo,
    /// extended into the gutter on any edge with a same-scene neighbor (`topMerged`/etc.) so
    /// adjacent cells' mats meet with no gap — together with each corner's `SceneBorderInfo
    /// .CornerKind` (see its own doc comment for the convex/concave/square logic), that's what
    /// makes an irregular block of same-scene cells read as one continuous, smoothly-jointed shape
    /// rather than a grid of separate square swatches. The scene's name is attached only once per
    /// group, to whichever cell is both the topmost row and the rightmost cell in that row — exactly
    /// the cell whose top-trailing corner is a true outer (`.convex`) corner.
    private func sceneBorderInfo(at index: Int, in items: [DisplayItem]) -> SceneBorderInfo? {
        guard let scene = currentScene(at: index, in: items) else { return nil }
        func neighbor(_ rowOffset: Int, _ colOffset: Int) -> Bool {
            sameSceneNeighbor(index, rowOffset: rowOffset, colOffset: colOffset, scene: scene, in: items)
        }
        let up = neighbor(-1, 0), down = neighbor(1, 0), leading = neighbor(0, -1), trailing = neighbor(0, 1)
        let upLeading = neighbor(-1, -1), upTrailing = neighbor(-1, 1)
        let downLeading = neighbor(1, -1), downTrailing = neighbor(1, 1)
        func corner(_ a: Bool, _ b: Bool, _ diagonal: Bool) -> SceneBorderInfo.CornerKind {
            if !a && !b { return .convex }
            if a && b && !diagonal { return .concave }
            return .square
        }
        let topTrailingKind = corner(up, trailing, upTrailing)
        return SceneBorderInfo(
            color: sceneBorderColor(for: scene),
            name: topTrailingKind == .convex ? scene.name : nil,
            topLeading: corner(up, leading, upLeading),
            topTrailing: topTrailingKind,
            bottomLeading: corner(down, leading, downLeading),
            bottomTrailing: corner(down, trailing, downTrailing),
            topMerged: up, bottomMerged: down, leadingMerged: leading, trailingMerged: trailing
        )
    }

    /// In Sessions mode a click only selects — opening a photo is the hover-revealed edit button
    /// (`PhotoThumbnailCell.onOpenEditor`) or Return. In Edit mode a click also opens the editor
    /// immediately. Either way this is exactly one tap gesture per cell, never a single-tap
    /// stacked alongside a `.onTapGesture(count: 2)` on the same view — two exclusive tap-count
    /// recognizers on one view forces SwiftUI to hold the single-click action until the double-
    /// click disambiguation window expires, which is what made every click feel laggy before.
    @ViewBuilder
    private func cell(for item: DisplayItem, at index: Int, in items: [DisplayItem]) -> some View {
        let sceneBorder = sceneBorderInfo(at: index, in: items)
        switch item {
        case .single(let asset):
            PhotoThumbnailCell(
                asset: asset, isSelected: selection.contains(asset.id), sceneBorder: sceneBorder,
                onOpenEditor: { onOpenEditor(asset) }
            )
            .id(asset.id)
            .onTapGesture { tap(asset.id, open: asset) }
        case .stackCover(let stack, let cover, let count):
            PhotoThumbnailCell(
                asset: cover,
                isSelected: selection.contains(cover.id),
                stackBadge: .collapsed(count: count),
                onToggleStack: { onToggleStack(stack.id, true) },
                sceneBorder: sceneBorder,
                onOpenEditor: { onOpenEditor(cover) }
            )
            .id(cover.id)
            .onTapGesture { tap(cover.id, open: cover) }
        case .stackMember(let asset, let position, let total):
            PhotoThumbnailCell(
                asset: asset,
                isSelected: selection.contains(asset.id),
                stackBadge: .expandedMember(position: position, total: total),
                onToggleStack: position == 1 ? { collapseStack(containing: asset) } : nil,
                sceneBorder: sceneBorder,
                onOpenEditor: { onOpenEditor(asset) }
            )
            .id(asset.id)
            .onTapGesture { tap(asset.id, open: asset) }
        }
    }

    private func tap(_ id: UUID, open asset: PhotoAsset) {
        handleClick(id)
        if isEditMode { onOpenEditor(asset) }
    }

    private func collapseStack(containing asset: PhotoAsset) {
        guard let stack = asset.stack else { return }
        onToggleStack(stack.id, false)
    }

    private func handleClick(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) {
                selection.remove(id)
            } else {
                selection.insert(id)
            }
        } else if flags.contains(.shift), let anchor = lastClickedID {
            let order = clickableIDsInOrder
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
                let range = a <= b ? a...b : b...a
                selection.formUnion(order[range])
            } else {
                selection = [id]
            }
        } else {
            selection = [id]
        }
        lastClickedID = id
        isFocused = true
    }

    private func moveFocus(to index: Int, order: [UUID], extend: Bool) {
        guard let target = order[safe: index] else { return }
        if extend, let anchor = lastClickedID, let anchorIndex = order.firstIndex(of: anchor) {
            let range = anchorIndex <= index ? anchorIndex...index : index...anchorIndex
            selection = Set(order[range])
        } else {
            selection = [target]
            lastClickedID = target
        }
        // Arrow-key navigation can move focus off-screen, unlike a mouse click — this is the one
        // path that's allowed to trigger the animated re-center scroll.
        scrollTarget = target
    }

    private func targetAssets(for ids: Set<UUID>) -> [PhotoAsset] {
        assets.filter { ids.contains($0.id) }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let order = clickableIDsInOrder
        guard !order.isEmpty else { return .ignored }
        let anchorID = lastClickedID ?? selection.first ?? order.first
        let currentIndex = anchorID.flatMap { order.firstIndex(of: $0) } ?? 0
        let extend = press.modifiers.contains(.shift)

        switch press.key {
        case .leftArrow:
            moveFocus(to: currentIndex - 1, order: order, extend: extend)
            return .handled
        case .rightArrow:
            moveFocus(to: currentIndex + 1, order: order, extend: extend)
            return .handled
        case .upArrow:
            moveFocus(to: currentIndex - columnCount, order: order, extend: extend)
            return .handled
        case .downArrow:
            moveFocus(to: currentIndex + columnCount, order: order, extend: extend)
            return .handled
        case .return:
            if let id = anchorID, let asset = assets.first(where: { $0.id == id }) {
                onOpenEditor(asset)
            }
            return .handled
        default:
            break
        }

        let targetIDs = selection.isEmpty ? Set(anchorID.map { [$0] } ?? []) : selection
        guard !targetIDs.isEmpty else { return .ignored }
        let targets = targetAssets(for: targetIDs)

        if let rating = Int(press.characters), (0...5).contains(rating), press.modifiers.isEmpty {
            for asset in targets { asset.rating = rating }
            persistSidecars(for: targets)
            onDataChanged()
            return .handled
        }

        switch press.characters.lowercased() {
        case "p":
            if targets.count == 1, let only = targets.first {
                only.flag = only.flag == .pick ? .none : .pick
            } else {
                for asset in targets { asset.flag = .pick }
            }
            persistSidecars(for: targets)
            onDataChanged()
            return .handled
        case "r":
            if targets.count == 1, let only = targets.first {
                only.flag = only.flag == .reject ? .none : .reject
            } else {
                for asset in targets { asset.flag = .reject }
            }
            persistSidecars(for: targets)
            onDataChanged()
            return .handled
        case "u":
            for asset in targets { asset.flag = .none }
            persistSidecars(for: targets)
            onDataChanged()
            return .handled
        case "g":
            if extend {
                onUnstack()
            } else {
                onGroupStack()
            }
            return .handled
        default:
            return .ignored
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
