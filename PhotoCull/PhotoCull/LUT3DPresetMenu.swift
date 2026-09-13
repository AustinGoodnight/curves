import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PhotoCatalog

/// The Film Simulation section's LUT picker — a scrollable list over the in-app library
/// (`LUT3DPreset`) instead of reopening Finder for every selection, or hiding the whole library
/// behind a closed dropdown; "Import LUT…" is still a `.fileImporter` sheet since a `.cube` file
/// has to come from disk at least once, but every reselection afterward is just clicking a name in
/// this list.
///
/// A genuine separate `View` type (not inline in `ColorBalanceBarView`), same reasoning as
/// `StackSceneControl` in `DetailPaneView.swift`: this is the only piece of the bottom bar with its own
/// `@Query`, and SwiftData's broad change-tracking means editing *any* `LUT3DPreset` anywhere
/// (importing, renaming, deleting) is enough to re-invoke a `body` that reads the query — scoping
/// that to this small list keeps it from also re-diffing the color wheels and Color Zones graph.
struct LUT3DPresetMenu: View {
    @Query(sort: \LUT3DPreset.name) private var presets: [LUT3DPreset]

    /// The stage's currently-applied LUT title, if any — the selected row's own name, compared by
    /// value since `LUT3DPreset` isn't copied by reference onto `Stage` (see `applyLUT3DPreset`'s
    /// doc comment).
    let currentTitle: String?
    var onSelect: (LUT3DPreset) -> Void
    var onImport: (URL) -> Void

    @State private var isImporting = false

    /// Tall enough to show ~3-4 rows before scrolling, short enough that a long library doesn't
    /// push the Intensity slider below it far down the column.
    private static let listHeight: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if presets.isEmpty {
                Text("No LUTs Imported")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(presets) { preset in
                            presetRow(preset)
                        }
                    }
                }
                .frame(height: Self.listHeight)
            }
            Button {
                isImporting = true
            } label: {
                Label("Import LUT…", systemImage: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .plainText]
        ) { result in
            if case .success(let url) = result {
                onImport(url)
            }
        }
    }

    /// Same "plain text, filled pill when selected" look as `ColorBalanceBarView`'s
    /// `colorZonesChannelSwitcher`/`channelTab` — one consistent selectable-row language across the
    /// editor instead of a native list-selection style here and a custom one there.
    private func presetRow(_ preset: LUT3DPreset) -> some View {
        let isSelected = preset.name == currentTitle
        return Button {
            onSelect(preset)
        } label: {
            Text(preset.name)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    isSelected ? Color.primary.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6)
                )
        }
        .buttonStyle(.plain)
    }
}
