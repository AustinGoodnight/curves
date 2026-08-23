import SwiftUI
import PhotoCatalog

/// Full-window, presentation-style review mode toggled from the toolbar (see `ContentView`'s
/// "Culling View" `Toggle`) — the current photo shown large and centered, with the previous/next
/// 3 photos as small columns on either side, so grading a session is a matter of arrow keys +
/// number/flag keys rather than clicking through the grid one photo at a time.
///
/// `currentIndex` is local `@State`, not `DetailStore` — it changes on every arrow-key press, and
/// per `CLAUDE.md`'s state-ownership rule that kind of high-frequency state belongs on the
/// smallest view that needs it, not on a shared object that would invalidate other views too.
/// `store.filteredAssets` is read once per `body` evaluation into a local `let` and threaded
/// through every helper as a parameter, matching `CullingGridView`'s own convention, rather than
/// re-reading `store.filteredAssets` from each helper independently.
struct CullingPresentationView: View {
    @Bindable var store: DetailStore
    var onOpenEditor: (PhotoAsset) -> Void
    /// Mirrors `GridPane.onDataChanged` — a closure (not a stored `allAssets` value parameter) so
    /// `ContentView`'s `@Query var allAssets` is only ever read lazily, at the moment a rating/flag
    /// keypress or click actually needs to recompute the filtered list. See `ContentView`'s header
    /// comment (trap #3) for why that distinction matters.
    var onDataChanged: () -> Void
    /// Fires when the "S" scene-mark shortcut closes a range — see `handleKeyPress`'s `"s"` case.
    /// A closure (not a direct `modelContext`/scene-creation call here) so `CullingPresentationView`
    /// stays free of SwiftData/session bookkeeping; `ContentView.beginSceneCreation(for:)` does the
    /// actual session-consistency check and drives the existing "New Scene" naming alert.
    var onCreateScene: (_ assets: [PhotoAsset]) -> Void

    @State private var currentIndex: Int = 0
    /// Set by the first "S" press (start of a scene range), cleared by the second (which closes
    /// the range and calls `onCreateScene`) — see `handleKeyPress`'s `"s"` case. Local `@State`,
    /// not `DetailStore`, for the same reason `currentIndex` is: nothing outside this view needs
    /// to react to it, and it should reset for free (no explicit cleanup) whenever this view is
    /// torn down and rebuilt by toggling culling view off and back on.
    @State private var sceneMarkStartIndex: Int?
    @FocusState private var isFocused: Bool

    var body: some View {
        let assets = store.filteredAssets
        Group {
            if assets.isEmpty {
                ContentUnavailableView(
                    "No Photos", systemImage: "photo.on.rectangle.angled",
                    description: Text("No photos match the current filter.")
                )
            } else {
                let idx = clampedIndex(currentIndex, count: assets.count)
                cullingContent(assets: assets, idx: idx)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.editorPreviewBackground)
        .focusable()
        .focused($isFocused)
        .onAppear {
            isFocused = true
            if let selectedID = store.selection.first, let idx = assets.firstIndex(where: { $0.id == selectedID }) {
                currentIndex = idx
            }
        }
        .onKeyPress { press in
            guard !assets.isEmpty else { return .ignored }
            return handleKeyPress(press, assets: assets, idx: clampedIndex(currentIndex, count: assets.count))
        }
    }

    private func clampedIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return min(max(index, 0), count - 1)
    }

    private func cullingContent(assets: [PhotoAsset], idx: Int) -> some View {
        let current = assets[idx]
        return VStack(spacing: 16) {
            HStack(spacing: 24) {
                sideColumn(assets: assets, idx: idx, offsets: [-3, -2, -1])
                CullingMainImage(asset: current)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                sideColumn(assets: assets, idx: idx, offsets: [1, 2, 3])
            }
            .padding(.horizontal, 32)
            .padding(.top, 24)

            gradingBar(assets: assets, current: current, idx: idx, total: assets.count)
                .padding(.bottom, 20)
        }
    }

    private func sideColumn(assets: [PhotoAsset], idx: Int, offsets: [Int]) -> some View {
        VStack(spacing: 14) {
            ForEach(offsets, id: \.self) { offset in
                let neighborIndex = idx + offset
                if assets.indices.contains(neighborIndex) {
                    CullingSideThumbnail(asset: assets[neighborIndex]) {
                        move(to: neighborIndex, in: assets)
                    }
                } else {
                    Color.clear.frame(height: 130)
                }
            }
        }
        .frame(width: 190)
    }

    private func gradingBar(assets: [PhotoAsset], current: PhotoAsset, idx: Int, total: Int) -> some View {
        VStack(spacing: 10) {
            Text(current.fileName)
                .font(.headline)
                .foregroundStyle(.white)
                .lineLimit(1)
            HStack(spacing: 20) {
                CullingRatingEditor(asset: current, onChange: onDataChanged)
                CullingFlagEditor(asset: current, onChange: onDataChanged)
            }
            Text("\(idx + 1) of \(total)")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.55))
            if let startIndex = sceneMarkStartIndex, assets.indices.contains(startIndex) {
                Text("Scene start marked at \"\(assets[startIndex].fileName)\" — press S again to close it here")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.yellow)
            }
            Text("← → Navigate · 0–5 Rate · P Pick · R Reject · U Unflag · S Mark Scene Start/End · Return Edit · Esc Exit")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private func move(to newIndex: Int, in assets: [PhotoAsset]) {
        let clamped = clampedIndex(newIndex, count: assets.count)
        currentIndex = clamped
        store.selection = [assets[clamped].id]
    }

    private func handleKeyPress(_ press: KeyPress, assets: [PhotoAsset], idx: Int) -> KeyPress.Result {
        let current = assets[idx]

        switch press.key {
        case .leftArrow, .upArrow:
            move(to: idx - 1, in: assets)
            return .handled
        case .rightArrow, .downArrow:
            move(to: idx + 1, in: assets)
            return .handled
        case .escape:
            store.isCullingViewActive = false
            return .handled
        case .return:
            onOpenEditor(current)
            return .handled
        default:
            break
        }

        if let rating = Int(press.characters), (0...5).contains(rating), press.modifiers.isEmpty {
            current.rating = rating
            onDataChanged()
            return .handled
        }

        switch press.characters.lowercased() {
        case "p":
            current.flag = current.flag == .pick ? .none : .pick
            onDataChanged()
            return .handled
        case "r":
            current.flag = current.flag == .reject ? .none : .reject
            onDataChanged()
            return .handled
        case "u":
            current.flag = .none
            onDataChanged()
            return .handled
        case "s":
            if let startIndex = sceneMarkStartIndex {
                let range = startIndex <= idx ? startIndex...idx : idx...startIndex
                onCreateScene(Array(assets[range]))
                sceneMarkStartIndex = nil
            } else {
                sceneMarkStartIndex = idx
            }
            return .handled
        default:
            return .ignored
        }
    }
}

/// The large, centered current photo. Loaded at a much bigger `maxPixelSize` than
/// `PhotoThumbnailCell`'s grid thumbnails, so it gets its own cache key (`#culling-preview`
/// suffix) rather than sharing `ThumbnailCache`'s plain-`filePath` key — using the same key would
/// mean whichever of the grid or this view loaded a given photo last overwrites the other's cached
/// size for it.
private struct CullingMainImage: View {
    let asset: PhotoAsset

    @State private var image: CGImage?

    private var cacheKey: String { asset.filePath + "#culling-preview" }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
            if asset.flag == .reject {
                Color.black.opacity(0.35)
            }
        }
        .overlay(alignment: .topTrailing) { flagBadge }
        .task(id: asset.filePath) {
            await load()
        }
    }

    @ViewBuilder private var flagBadge: some View {
        switch asset.flag {
        case .pick:
            Image(systemName: "flag.fill")
                .foregroundStyle(.green)
                .padding(8)
                .background(.thinMaterial, in: Circle())
                .padding(8)
        case .reject:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
                .padding(8)
                .background(.thinMaterial, in: Circle())
                .padding(8)
        case .none:
            EmptyView()
        }
    }

    private func load() async {
        if let cached = ThumbnailCache.shared.image(for: cacheKey) {
            image = cached
            return
        }
        let url = asset.resolvedURL()
        let loaded = await Task.detached(priority: .userInitiated) {
            ThumbnailProvider.thumbnail(for: url, maxPixelSize: 2048)
        }.value
        if let loaded {
            ThumbnailCache.shared.setImage(loaded, for: cacheKey)
            image = loaded
        }
    }
}

/// A small neighbor thumbnail in the previous/next-3 side columns. Deliberately not
/// `PhotoThumbnailCell` — that view carries grid-only chrome (stack badges, scene borders, a
/// hover-revealed edit button) that doesn't apply to a fixed-size side column here. Shares
/// `ThumbnailCache`'s plain-`filePath` key with `PhotoThumbnailCell`, so a photo already thumbed
/// in the grid doesn't get re-decoded just for appearing in this column.
private struct CullingSideThumbnail: View {
    @Bindable var asset: PhotoAsset
    var onSelect: () -> Void

    @State private var thumbnail: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.gray.opacity(0.15))
                if let thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
                if asset.flag == .reject {
                    Color.black.opacity(0.35)
                }
            }
            .frame(height: 130)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topTrailing) { flagGlyph }

            if asset.rating > 0 {
                Text(String(repeating: "★", count: asset.rating))
                    .font(.caption2)
                    .foregroundStyle(.yellow)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .task(id: asset.filePath) {
            await loadThumbnail()
        }
    }

    @ViewBuilder private var flagGlyph: some View {
        switch asset.flag {
        case .pick:
            Image(systemName: "flag.fill").font(.caption2).foregroundStyle(.green).padding(3)
        case .reject:
            Image(systemName: "xmark.circle.fill").font(.caption2).foregroundStyle(.red).padding(3)
        case .none:
            EmptyView()
        }
    }

    private func loadThumbnail() async {
        let key = asset.filePath
        if let cached = ThumbnailCache.shared.image(for: key) {
            thumbnail = cached
            return
        }
        let url = asset.resolvedURL()
        let loaded = await Task.detached(priority: .userInitiated) {
            ThumbnailProvider.thumbnail(for: url)
        }.value
        if let loaded {
            ThumbnailCache.shared.setImage(loaded, for: key)
            thumbnail = loaded
        }
    }
}

/// Interactive per-photo star rating for the grading bar — distinct from the toolbar's
/// `RatingFilterControl`, which sets a *filter* threshold rather than an individual photo's
/// rating. Tapping the already-set star clears the rating back to 0, matching the same
/// toggle-off convention used throughout (`RatingFilterControl`, `CullingGridView`'s number-key
/// handler).
private struct CullingRatingEditor: View {
    @Bindable var asset: PhotoAsset
    var onChange: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    asset.rating = asset.rating == star ? 0 : star
                    onChange()
                } label: {
                    Image(systemName: star <= asset.rating ? "star.fill" : "star")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .foregroundStyle(star <= asset.rating ? Color.yellow : Color.white.opacity(0.4))
            }
        }
    }
}

/// Interactive per-photo Pick/Reject toggle for the grading bar — see `CullingRatingEditor`'s doc
/// comment for why this is separate from the toolbar's `FlagFilterControl`.
private struct CullingFlagEditor: View {
    @Bindable var asset: PhotoAsset
    var onChange: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            flagButton(.pick, systemImage: "flag.fill", color: .green)
            flagButton(.reject, systemImage: "xmark.circle.fill", color: .red)
        }
    }

    private func flagButton(_ flag: FlagState, systemImage: String, color: Color) -> some View {
        let isActive = asset.flag == flag
        return Button {
            asset.flag = isActive ? .none : flag
            onChange()
        } label: {
            Image(systemName: systemImage).font(.title3)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? color : Color.white.opacity(0.4))
    }
}
