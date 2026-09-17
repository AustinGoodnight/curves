import SwiftUI
import PhotoCatalog

/// Shared by `CompactPhotoThumbnail` and `FilmstripThumbnail` — same cache/decode path
/// `PhotoThumbnailCell.loadThumbnail` uses, factored out since both need it with different chrome
/// wrapped around it.
private func loadCachedThumbnail(for asset: PhotoAsset) async -> CGImage? {
    let key = asset.filePath
    if let cached = ThumbnailCache.shared.image(for: key) {
        return cached
    }
    let url = asset.resolvedURL()
    let image = await Task.detached(priority: .userInitiated) {
        ThumbnailProvider.thumbnail(for: url)
    }.value
    if let image {
        ThumbnailCache.shared.setImage(image, for: key)
    }
    return image
}

/// A small, fixed-size square thumbnail — used by `StagesSidebarView`'s "Stack" section, next to a
/// filename in a row. See `FilmstripThumbnail` for the full-width, no-card style
/// `SessionFilmstripView` uses instead.
struct CompactPhotoThumbnail: View {
    let asset: PhotoAsset
    let isCurrent: Bool
    var size: CGFloat = 96

    @State private var thumbnail: CGImage?
    @Environment(ColorSchemeStore.self) private var uiColors

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
                .stroke(isCurrent ? uiColors.accentColor : .clear, lineWidth: 3)
        )
        .task(id: "\(asset.filePath)#\(ThumbnailInvalidationBus.shared.box(for: asset.filePath).value)") {
            thumbnail = await loadCachedThumbnail(for: asset)
        }
    }
}

/// One full-width row in `SessionFilmstripView` — no card background, no fixed size, no padding
/// "wrapper" around it: the photo renders edge-to-edge at its own aspect ratio, the way a real
/// contact-sheet filmstrip looks. `Image.aspectRatio(_:contentMode:)` given an explicit ratio (not
/// just a `ContentMode`) is what makes `.frame(maxWidth: .infinity)` alone enough to get the right
/// height — no `GeometryReader` needed to read back an available width.
private struct FilmstripThumbnail: View {
    let asset: PhotoAsset
    let isCurrent: Bool
    let stackCount: Int

    @State private var thumbnail: CGImage?
    @Environment(ColorSchemeStore.self) private var uiColors

    /// From the *loaded thumbnail's* own pixel dimensions, not `asset.pixelWidth`/`pixelHeight` —
    /// those are the raw sensor buffer's dimensions and ignore the shot's EXIF orientation, so a
    /// portrait photo from a rotated sensor reports landscape width/height and rendered cropped to
    /// horizontal here. `ThumbnailProvider.thumbnail(for:)` decodes with
    /// `kCGImageSourceCreateThumbnailWithTransform: true`, which *does* apply that rotation, so the
    /// decoded `CGImage`'s own `width`/`height` are already correctly oriented. Square (1:1) until
    /// the thumbnail loads — better an honest, brief placeholder shape than a confidently wrong one.
    private var aspectRatio: CGFloat {
        guard let thumbnail, thumbnail.width > 0, thumbnail.height > 0 else { return 1 }
        return CGFloat(thumbnail.width) / CGFloat(thumbnail.height)
    }

    var body: some View {
        ZStack {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(aspectRatio, contentMode: .fit)
            } else {
                Color.gray.opacity(0.15)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay {
            if isCurrent {
                RoundedRectangle(cornerRadius: 5).stroke(uiColors.accentColor, lineWidth: 3)
            }
        }
        .overlay(alignment: .bottomLeading) { stackBadge }
        .task(id: "\(asset.filePath)#\(ThumbnailInvalidationBus.shared.box(for: asset.filePath).value)") {
            thumbnail = await loadCachedThumbnail(for: asset)
        }
    }

    /// Draws only for a collapsed-stack entry (`stackCount > 1`) — same "square.stack + count"
    /// treatment `PhotoThumbnailCell.stackBadgeView` uses for a stack cover in the main grid.
    @ViewBuilder private var stackBadge: some View {
        if stackCount > 1 {
            HStack(spacing: 2) {
                Image(systemName: "square.stack.fill")
                Text("\(stackCount)")
            }
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.thinMaterial, in: Capsule())
            .padding(4)
        }
    }
}

/// Vertical filmstrip of every photo in the current asset's session — lets you jump between photos
/// without leaving the editor. A distinct panel from `StagesSidebarView`'s "Stack" section: this
/// one is about *which* photo is open; that one is about a single photo's own edit stack.
///
/// `ContentView` constructs this as a sibling of `EditorView`, not as a child of it, specifically so
/// this view's own identity — and its `ScrollView`'s scroll position — survives switching photos.
/// `EditorView` carries `.id(editingAsset.id)` to force a fresh copy of *itself* (and its per-photo
/// `@State`: render coordinator, undo history, selected stage) on every switch; this view has no
/// such per-photo state to reset, so keeping it outside that `.id()` boundary means clicking a
/// thumbnail here only updates its `asset`/`onSelectAsset` values in place instead of tearing down
/// and rebuilding the whole panel — which is also what previously reset its scroll position to the
/// top on every single click.
struct SessionFilmstripView: View {
    let asset: PhotoAsset
    /// Read only for `passesActiveFilters` in `filmstripItems` — the culling view's rating/flag/
    /// file-type filters, which should also thin out this session-scoped list rather than only
    /// applying to the grid. A plain `let` (not `@Bindable`) since nothing here writes to it; as its
    /// own `View` type, reading `store`'s properties still scopes Observation invalidation to just
    /// this view, not `ContentView`'s.
    let store: DetailStore
    var onSelectAsset: (PhotoAsset) -> Void
    @Environment(ColorSchemeStore.self) private var uiColors

    /// One entry per *shot*, not per photo — a stack collapses to a single thumbnail here (with a
    /// count badge, see `FilmstripThumbnail.stackBadge`), same as the main grid's stack cover, since
    /// this panel is about picking which shot to look at. `StagesSidebarView`'s "Stack" section is
    /// where you pick a specific take within one. The representative for a stack the currently-open
    /// photo belongs to is `asset` itself (so the filmstrip shows the actual open photo, not always
    /// the stack's earliest member); for any other stack it's just the earliest member. Reads
    /// `asset.session?.photos` — a relationship on the one already-in-memory asset being edited,
    /// bounded to that session's size, not a library-wide `@Query` scan. Not the trap `CLAUDE.md`
    /// warns about (that's specifically about `ContentView`'s `@Query var allAssets`).
    private struct Item: Identifiable {
        let photo: PhotoAsset
        let stackCount: Int
        var id: UUID { photo.id }
    }

    /// The currently-open `asset` is always kept, even if it no longer passes the active filters
    /// (e.g. the user changes the file-type filter while a non-matching photo is open) — losing the
    /// photo you're actively editing out of its own filmstrip would be more surprising than useful.
    private var filmstripItems: [Item] {
        guard let session = asset.session else { return [Item(photo: asset, stackCount: 1)] }
        let visibleIDs = Set((session.photos ?? [])
            .filter { store.passesActiveFilters($0) || $0.id == asset.id }
            .map(\.id))
        let sorted = (session.photos ?? [])
            .filter { visibleIDs.contains($0.id) }
            .sorted { ($0.captureDate ?? $0.importDate) < ($1.captureDate ?? $1.importDate) }
        var seenStacks = Set<UUID>()
        var result: [Item] = []
        for photo in sorted {
            guard let stack = photo.stack else {
                result.append(Item(photo: photo, stackCount: 1))
                continue
            }
            guard !seenStacks.contains(stack.id) else { continue }
            seenStacks.insert(stack.id)
            let members = (stack.photos ?? []).filter { visibleIDs.contains($0.id) }
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
                .padding(.vertical, 10)
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(filmstripItems) { item in
                        FilmstripThumbnail(asset: item.photo, isCurrent: item.photo.id == asset.id, stackCount: item.stackCount)
                            .id(item.photo.id)
                            .onTapGesture { onSelectAsset(item.photo) }
                    }
                }
                .padding(12)
            }
        }
        .frame(minWidth: 130, idealWidth: 150, maxWidth: 200)
        .background(uiColors.sidebarBackground)
    }
}
