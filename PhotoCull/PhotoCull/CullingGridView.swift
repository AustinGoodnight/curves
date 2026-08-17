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
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: spacing) {
                        ForEach(displayItems) { item in
                            cell(for: item)
                        }
                    }
                    .padding(spacing)
                }
                .onChange(of: lastClickedID) { _, newValue in
                    if let newValue {
                        withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }
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

    @ViewBuilder
    private func cell(for item: DisplayItem) -> some View {
        switch item {
        case .single(let asset):
            PhotoThumbnailCell(asset: asset, isSelected: selection.contains(asset.id))
                .id(asset.id)
                .onTapGesture(count: 2) { onOpenEditor(asset) }
                .onTapGesture { handleClick(asset.id) }
        case .stackCover(let stack, let cover, let count):
            PhotoThumbnailCell(
                asset: cover,
                isSelected: selection.contains(cover.id),
                stackBadge: .collapsed(count: count),
                onToggleStack: { expandedStacks.insert(stack.id) }
            )
            .id(cover.id)
            .onTapGesture(count: 2) { onOpenEditor(cover) }
            .onTapGesture { handleClick(cover.id) }
        case .stackMember(let asset, let position, let total):
            PhotoThumbnailCell(
                asset: asset,
                isSelected: selection.contains(asset.id),
                stackBadge: .expandedMember(position: position, total: total),
                onToggleStack: position == 1 ? { collapseStack(containing: asset) } : nil
            )
            .id(asset.id)
            .onTapGesture(count: 2) { onOpenEditor(asset) }
            .onTapGesture { handleClick(asset.id) }
        }
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
        case "x":
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
