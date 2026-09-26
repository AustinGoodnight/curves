import SwiftUI

/// The Film Simulation section's LUT picker — a scrollable list over the visible `.cube` files in
/// the LUT folder chosen in Settings (`LUTLibrary`), instead of a per-file import flow. Hiding a
/// LUT, or changing the folder, also happens in Settings; this list just reflects it.
///
/// A genuine separate `View` type (not inline in `ColorBalanceBarView`), same reasoning as
/// `StackSceneControl` in `DetailPaneView.swift`: this is the only piece of the bottom bar that
/// reads `LUTLibrary`, so a rescan or hide/unhide only re-invokes this small list's `body`, not the
/// color wheels and Color Zones graph beside it.
struct LUT3DPresetMenu: View {
    @Environment(LUTLibrary.self) private var library

    /// The stage's currently-applied LUT title, if any — compared against each entry's `name`,
    /// since that's what `ColorBalanceBarView.applyLUT(_:)` copies onto `Stage.lut3DTitle`.
    let currentTitle: String?
    var onSelect: (LUTLibraryEntry) -> Void

    /// Tall enough to show ~3-4 rows before scrolling, short enough that a long library doesn't
    /// push the Intensity slider below it far down the column.
    private static let listHeight: CGFloat = 96

    var body: some View {
        let entries = library.visibleEntries
        VStack(alignment: .leading, spacing: 6) {
            if entries.isEmpty {
                Text(library.folderURL == nil ? "No LUT Folder Set" : "No LUTs in Folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingsLink {
                    Label("Choose in Settings…", systemImage: "folder")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(entries) { entry in
                            entryRow(entry)
                        }
                    }
                }
                .frame(height: Self.listHeight)
            }
        }
        .onAppear { library.rescan() }
    }

    /// Same "plain text, filled pill when selected" look as `ColorBalanceBarView`'s
    /// `colorZonesChannelSwitcher`/`channelTab` — one consistent selectable-row language across the
    /// editor instead of a native list-selection style here and a custom one there.
    private func entryRow(_ entry: LUTLibraryEntry) -> some View {
        let isSelected = entry.name == currentTitle
        return Button {
            onSelect(entry)
        } label: {
            Text(entry.name)
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
