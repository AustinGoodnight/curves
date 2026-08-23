import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PhotoCatalog

/// The Film Simulation section's LUT picker — a menu over the in-app library (`LUT3DPreset`)
/// instead of reopening Finder for every selection; "Import LUT…" is still a `.fileImporter` sheet
/// since a `.cube` file has to come from disk at least once, but every reselection afterward is
/// just picking a name from this list.
///
/// A genuine separate `View` type (not inline in `ColorBalanceBarView`), same reasoning as
/// `OrganizeMenu` in `DetailPaneView.swift`: this is the only piece of the bottom bar with its own
/// `@Query`, and SwiftData's broad change-tracking means editing *any* `LUT3DPreset` anywhere
/// (importing, renaming, deleting) is enough to re-invoke a `body` that reads the query — scoping
/// that to this small menu keeps it from also re-diffing the color wheels and Color Zones graph.
struct LUT3DPresetMenu: View {
    @Query(sort: \LUT3DPreset.name) private var presets: [LUT3DPreset]

    /// The stage's currently-applied LUT title, if any — shown as the menu's own label so the
    /// button doubles as a "what's active" readout.
    let currentTitle: String?
    var onSelect: (LUT3DPreset) -> Void
    var onImport: (URL) -> Void

    @State private var isImporting = false

    var body: some View {
        Menu {
            if presets.isEmpty {
                Text("No LUTs Imported")
            } else {
                ForEach(presets) { preset in
                    Button(preset.name) { onSelect(preset) }
                }
                Divider()
            }
            Button("Import LUT…") { isImporting = true }
        } label: {
            HStack(spacing: 4) {
                Text(currentTitle ?? "Choose LUT…")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .font(.caption)
            .foregroundStyle(currentTitle == nil ? Color.accentColor : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType(filenameExtension: "cube") ?? .plainText]
        ) { result in
            if case .success(let url) = result {
                onImport(url)
            }
        }
    }
}
