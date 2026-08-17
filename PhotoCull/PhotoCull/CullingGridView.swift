import SwiftUI
import PhotoCatalog

struct CullingGridView: View {
    let assets: [PhotoAsset]

    @State private var selection: UUID?
    @State private var columnCount: Int = 5
    @FocusState private var isFocused: Bool

    private let cellWidth: CGFloat = 180
    private let spacing: CGFloat = 12

    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: spacing), count: max(columnCount, 1))
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: gridColumns, spacing: spacing) {
                        ForEach(assets) { asset in
                            PhotoThumbnailCell(asset: asset, isSelected: asset.id == selection)
                                .id(asset.id)
                                .onTapGesture {
                                    selection = asset.id
                                    isFocused = true
                                }
                        }
                    }
                    .padding(spacing)
                }
                .onChange(of: selection) { _, newValue in
                    if let newValue {
                        withAnimation { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }
            }
            .onAppear {
                updateColumnCount(for: geo.size.width)
                if selection == nil { selection = assets.first?.id }
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

    private func updateColumnCount(for width: CGFloat) {
        columnCount = max(1, Int(width / (cellWidth + spacing)))
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        guard !assets.isEmpty else { return .ignored }
        let currentIndex = selection.flatMap { sel in assets.firstIndex(where: { $0.id == sel }) } ?? 0

        switch press.key {
        case .leftArrow:
            move(to: currentIndex - 1)
            return .handled
        case .rightArrow:
            move(to: currentIndex + 1)
            return .handled
        case .upArrow:
            move(to: currentIndex - columnCount)
            return .handled
        case .downArrow:
            move(to: currentIndex + columnCount)
            return .handled
        default:
            break
        }

        guard let asset = assets[safe: currentIndex] else { return .ignored }

        if let rating = Int(press.characters), (0...5).contains(rating) {
            asset.rating = rating
            return .handled
        }

        switch press.characters.lowercased() {
        case "p":
            asset.flag = asset.flag == .pick ? .none : .pick
            return .handled
        case "x":
            asset.flag = asset.flag == .reject ? .none : .reject
            return .handled
        case "u":
            asset.flag = .none
            return .handled
        default:
            return .ignored
        }
    }

    private func move(to index: Int) {
        guard let asset = assets[safe: index] else { return }
        selection = asset.id
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
