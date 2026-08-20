import SwiftUI
import PhotoCatalog

/// A small thumbnail used by `SessionFilmstripView` and `StagesSidebarView`'s "Stack" section —
/// same cache/load path as `PhotoThumbnailCell`, without any of the grid's rating/flag/stack-badge
/// chrome that neither of these two spots needs.
struct CompactPhotoThumbnail: View {
    let asset: PhotoAsset
    let isCurrent: Bool
    var size: CGFloat = 96
    /// Non-nil and >1 only for `SessionFilmstripView`'s collapsed-stack entries — draws the same
    /// "square.stack + count" badge `PhotoThumbnailCell.stackBadgeView` draws for a stack cover in
    /// the main grid. `nil` everywhere else (including `StagesSidebarView`'s "Stack" section, where
    /// every entry is already a specific single photo — a count badge there would be redundant).
    var stackCount: Int? = nil

    @State private var thumbnail: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.gray.opacity(0.15))
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isCurrent ? Color.accentColor : .clear, lineWidth: 3)
        )
        .overlay(alignment: .bottomLeading) { stackBadge }
        .task(id: asset.filePath) {
            await loadThumbnail()
        }
    }

    @ViewBuilder private var stackBadge: some View {
        if let stackCount, stackCount > 1 {
            HStack(spacing: 2) {
                Image(systemName: "square.stack.fill")
                Text("\(stackCount)")
            }
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
            .padding(3)
        }
    }

    private func loadThumbnail() async {
        let key = asset.filePath
        if let cached = ThumbnailCache.shared.image(for: key) {
            thumbnail = cached
            return
        }
        let url = asset.resolvedURL()
        let image = await Task.detached(priority: .userInitiated) {
            ThumbnailProvider.thumbnail(for: url)
        }.value
        if let image {
            ThumbnailCache.shared.setImage(image, for: key)
            thumbnail = image
        }
    }
}

/// Vertical filmstrip of every photo in the current asset's session — lets you jump between photos
/// without leaving the editor. A distinct panel from `StagesSidebarView`'s "Stack" section: this
/// one is about *which* photo is open; that one is about a single photo's own edit stack.
struct SessionFilmstripView: View {
    let asset: PhotoAsset
    var onSelectAsset: (PhotoAsset) -> Void

    /// One entry per *shot*, not per photo — a stack collapses to a single thumbnail here (with a
    /// count badge, see `stackCount`), same as the main grid's stack cover, since this panel is
    /// about picking which shot to look at. `StagesSidebarView`'s "Stack" section is where you pick
    /// a specific take within one. The representative for a stack the currently-open photo belongs
    /// to is `asset` itself (so the filmstrip shows the actual open photo, not always the stack's
    /// earliest member); for any other stack it's just the earliest member. Reads
    /// `asset.session?.photos` — a relationship on the one already-in-memory asset being edited,
    /// bounded to that session's size, not a library-wide `@Query` scan. Not the trap `CLAUDE.md`
    /// warns about (that's specifically about `ContentView`'s `@Query var allAssets`).
    private struct Item: Identifiable {
        let photo: PhotoAsset
        /// 1 for an unstacked photo — `CompactPhotoThumbnail` only draws a badge above 1.
        let stackCount: Int
        var id: UUID { photo.id }
    }

    private var filmstripItems: [Item] {
        guard let session = asset.session else { return [Item(photo: asset, stackCount: 1)] }
        let sorted = (session.photos ?? []).sorted { ($0.captureDate ?? $0.importDate) < ($1.captureDate ?? $1.importDate) }
        var seenStacks = Set<UUID>()
        var result: [Item] = []
        for photo in sorted {
            guard let stack = photo.stack else {
                result.append(Item(photo: photo, stackCount: 1))
                continue
            }
            guard !seenStacks.contains(stack.id) else { continue }
            seenStacks.insert(stack.id)
            let members = stack.photos ?? []
            let containsCurrent = members.contains { $0.id == asset.id }
            result.append(Item(photo: containsCurrent ? asset : photo, stackCount: members.count))
        }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Session")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 10)
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(filmstripItems) { item in
                        CompactPhotoThumbnail(
                            asset: item.photo, isCurrent: item.photo.id == asset.id, size: 120, stackCount: item.stackCount
                        )
                        .id(item.photo.id)
                        .onTapGesture { onSelectAsset(item.photo) }
                    }
                }
                .padding(10)
            }
        }
        .frame(minWidth: 130, idealWidth: 150, maxWidth: 200)
        .background(Color.sidebarBackground)
    }
}
