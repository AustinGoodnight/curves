import SwiftUI
import SwiftData
import PhotoCatalog

/// The "Copy from Recent" list, below "Stack"/"Presets" in `StagesSidebarView` — lets you pull
/// another photo's current edit onto this one without having to save it as a named `Preset` first.
/// A genuine separate `View` type (not inline in `StagesSidebarView.body`), same isolation reasoning
/// as `PresetBrowserView`/`FilmSimulationPicker`: this is the one place with its own `@Query`, and
/// SwiftData's broad change-tracking means opening *any* photo in the editor (which touches
/// `lastEditedDate`) is enough to re-invoke a `body` that reads the query, so scoping that to this
/// small section keeps it from also re-diffing the stage list, Versions, and History sections above
/// it.
///
/// Applying a row (tapping it) always adds a new **custom stage** to the currently-open photo, the
/// same "never overwrite, always append" shape `StagesSidebarView.applyPreset(_:)` uses — see that
/// function's own doc comment. The source photo's *whole active stack* is flattened into that one
/// new stage via `StageFieldSnapshot(mergingActiveStages:)`, exactly like "Save All Stages as
/// Preset…" does — not a stage-for-stage copy including masks, since a source photo's spatial mask
/// (built against that photo's own pixels) wouldn't mean anything applied to a different photo.
struct RecentEditsBrowserView: View {
    let currentAssetID: UUID
    var onApply: (PhotoAsset) -> Void

    /// `fetchLimit` set higher than the `prefix` below keeps applying — the current photo itself is
    /// usually the most-recently-opened, so it's expected to occupy one of these slots before being
    /// filtered out in `body`.
    @Query private var recentlyOpened: [PhotoAsset]

    init(currentAssetID: UUID, onApply: @escaping (PhotoAsset) -> Void) {
        self.currentAssetID = currentAssetID
        self.onApply = onApply
        var descriptor = FetchDescriptor<PhotoAsset>(
            predicate: #Predicate { $0.lastEditedDate != nil },
            sortBy: [SortDescriptor(\.lastEditedDate, order: .reverse)]
        )
        descriptor.fetchLimit = 12
        _recentlyOpened = Query(descriptor)
    }

    private var rows: [PhotoAsset] {
        Array(recentlyOpened.filter { $0.id != currentAssetID }.prefix(6))
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                Text("No Recent Edits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { photo in
                    Button {
                        onApply(photo)
                    } label: {
                        HStack(spacing: 8) {
                            CompactPhotoThumbnail(asset: photo, isCurrent: false, size: 36)
                            Text(photo.fileName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
