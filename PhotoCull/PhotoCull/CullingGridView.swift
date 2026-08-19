import SwiftUI
import AppKit
import PhotoCatalog

private enum DisplayItem: Identifiable {
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

struct CullingGridView: View {
    let assets: [PhotoAsset]
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

    @State private var expandedStacks: Set<UUID> = []
    @State private var lastClickedID: UUID?
    @State private var columnCount: Int = 5
    @FocusState private var isFocused: Bool

    private let cellWidth: CGFloat = 180
    private let spacing: CGFloat = 12

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: max(columnCount, 1))
    }

    /// ⚠️ Rebuilds the *entire* grid's worth of items from scratch on every access (O(n), with an
    /// O(n) inner scan per stack) — see `CLAUDE.md` incident #4. Never call this more than once
    /// per `body` evaluation, and never from a function that runs per-cell (`cell(for:at:in:)` and
    /// friends take an already-computed `items` array as a parameter for exactly this reason).
    private var displayItems: [DisplayItem] {
        var seenStacks = Set<UUID>()
        var items: [DisplayItem] = []
        for asset in assets {
            if let stack = asset.stack {
                guard !seenStacks.contains(stack.id) else { continue }
                seenStacks.insert(stack.id)
                let visibleMembers = (stack.photos ?? [])
                    .filter { member in assets.contains(where: { $0.id == member.id }) }
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
        return items
    }

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
        // Computed once per body pass and threaded through explicitly (`cell(for:at:in:)`,
        // `sceneBorderInfo`, `currentScene`) rather than left as repeated reads of the
        // `displayItems` computed property — `displayItems` rebuilds the *entire* list (1000s of
        // items, with an O(n) inner scan per stack) from scratch on every access. Building the
        // scene border for one cell used to call `currentScene(at:)` up to 5 times (self + 4
        // neighbors), each of which read `displayItems` twice (`.indices.contains` and the
        // subscript) — roughly 10 full rebuilds *per visible cell*, for every visible cell, on
        // every render. That's the exact "computed property read too many times" trap from
        // `CLAUDE.md`, just newly reintroduced here instead of in `ContentView`.
        let items = displayItems
        return GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: spacing) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            cell(for: item, at: index, in: items)
                        }
                    }
                    .padding(spacing)
                }
                .onChange(of: lastClickedID) { _, newValue in
                    if let newValue {
                        withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }
                .background(Color.workspaceBackground)
            }
            .onAppear {
                updateColumnCount(for: geo.size.width)
                if selection.isEmpty, let first = clickableIDsInOrder.first {
                    selection = [first]
                    lastClickedID = first
                }
            }
            .onChange(of: geo.size.width) { _, newWidth in
                updateColumnCount(for: newWidth)
            }
        }
        .focusable()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onKeyPress(action: handleKeyPress)
    }

    /// Which scene (if any) the item at `index` belongs to — used both directly and to compare a
    /// cell against its grid neighbors when building `sceneBorderInfo(at:in:)`. Takes the already-
    /// computed `items` array rather than reading `displayItems` itself — see `body`'s comment for
    /// why re-deriving it here would be catastrophically expensive.
    private func currentScene(at index: Int, in items: [DisplayItem]) -> PhotoScene? {
        guard items.indices.contains(index) else { return nil }
        switch items[index] {
        case .single(let asset): return asset.scene
        case .stackCover(_, let cover, _): return cover.scene
        case .stackMember(let asset, _, _): return asset.scene
        }
    }

    /// Builds the per-edge merge state a contiguous block of same-scene cells needs to read as
    /// one wrapping outline rather than N individual rings — see `SceneBorderInfo`'s doc comment
    /// for how `PhotoThumbnailCell` turns this into an actual seamless shape. An edge is "merged"
    /// (no stroke, extends into the gutter instead) only when the neighbor in that direction is a
    /// *different* display item in the same scene; the grid's own boundary (first/last column,
    /// first/last item) always counts as a boundary edge. The scene's name is attached only to the
    /// group's top-right corner cell (`!topMerged && !trailingMerged`) so it's shown once per
    /// group, "inside the border" near its top-right — not once per photo.
    private func sceneBorderInfo(at index: Int, in items: [DisplayItem]) -> SceneBorderInfo? {
        guard let scene = currentScene(at: index, in: items) else { return nil }
        let col = index % max(columnCount, 1)
        let leadingMerged = col > 0 && currentScene(at: index - 1, in: items)?.id == scene.id
        let trailingMerged = col < columnCount - 1 && index + 1 < items.count && currentScene(at: index + 1, in: items)?.id == scene.id
        let topMerged = index - columnCount >= 0 && currentScene(at: index - columnCount, in: items)?.id == scene.id
        let bottomMerged = index + columnCount < items.count && currentScene(at: index + columnCount, in: items)?.id == scene.id
        return SceneBorderInfo(
            color: sceneBorderColor(for: scene),
            name: (!topMerged && !trailingMerged) ? scene.name : nil,
            topMerged: topMerged, bottomMerged: bottomMerged,
            leadingMerged: leadingMerged, trailingMerged: trailingMerged
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
                onToggleStack: { expandedStacks.insert(stack.id) },
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
        expandedStacks.remove(stack.id)
    }

    private func updateColumnCount(for width: CGFloat) {
        columnCount = max(1, Int(width / (cellWidth + spacing)))
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
            return .handled
        }

        switch press.characters.lowercased() {
        case "p":
            if targets.count == 1, let only = targets.first {
                only.flag = only.flag == .pick ? .none : .pick
            } else {
                for asset in targets { asset.flag = .pick }
            }
            return .handled
        case "r":
            if targets.count == 1, let only = targets.first {
                only.flag = only.flag == .reject ? .none : .reject
            } else {
                for asset in targets { asset.flag = .reject }
            }
            return .handled
        case "u":
            for asset in targets { asset.flag = .none }
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
