import SwiftUI
import PhotoCatalog
import RawEngine

/// The Film Simulation browser — takes over the editor's right sidebar (opened from the Browse
/// button in `ColorBalanceBarView`'s Film Simulation header, closed with Done/Esc), so LUT picking
/// gets a big visual surface only while it's actually being used and the bottom bar's list stays
/// compact the rest of the time.
///
/// Two ways in, both showing *this photo* rather than LUT names alone:
/// - **Hero preview** (top): the current look, large. Swipe/drag it sideways (or ‹ ›) to step to
///   the previous/next LUT — each step applies to the main image, so the full-size photo is the
///   real preview. The flat descendant of the Developer Mode "Film Roll Shuffle" concept: same
///   shuffle gesture, but with a readable preview and the look's name/folder/position instead of
///   a decorative canister.
/// - **Contact sheet** (below): every LUT as a thumbnail of the photo; click to apply.
///
/// Thumbnails come from `LUTPreviewStore` — a small snapshot of the photo without its LUT, taken
/// when the browser opens (and on Refresh / switching photos), not re-rendered on every edit.
struct LUTBrowserSidebar: View {
    let actions: LUTConceptActions
    var onRefresh: () -> Void
    var onClose: () -> Void
    @Environment(LUTLibrary.self) private var library
    @Environment(ColorSchemeStore.self) private var uiColors
    @State private var dragOffset: CGFloat = 0
    /// Which way the last step went — drives the hero's slide-in direction.
    @State private var stepDirection: Edge = .trailing

    var body: some View {
        let entries = library.visibleEntries
        let currentIndex = entries.firstIndex { $0.name == actions.currentTitle }
        VStack(alignment: .leading, spacing: 14) {
            header
            if entries.isEmpty {
                emptyLibraryNote(library)
                Spacer()
            } else {
                hero(entries: entries, currentIndex: currentIndex)
                if actions.currentTitle != nil {
                    slider(
                        "Strength", value: actions.intensity, range: 0...1, resetValue: 1,
                        ticks: [0, 0.25, 0.5, 0.75, 1], trackStyle: .hairline, thumbShape: .diamond
                    )
                }
                contactSheet(entries: entries)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(uiColors.sidebarBackground)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            sectionTitle("Film Simulation", enabled: nil)
            Spacer()
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise").font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Re-render the previews from the photo's current edits")
            Button("Done", action: onClose)
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.white.opacity(0.1), in: Capsule())
                .keyboardShortcut(.cancelAction)
        }
    }

    // MARK: Hero

    private func hero(entries: [LUTLibraryEntry], currentIndex: Int?) -> some View {
        let current = currentIndex.map { entries[$0] }
        let parts = current.map(Self.split) ?? (folder: nil, name: "None")
        return VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(uiColors.recessedTrackBackground)
                Group {
                    if let current {
                        LUTThumbnail(entry: current, store: actions.store, height: 190)
                    } else if let base = actions.store.baseImage {
                        Image(decorative: base, scale: 1).resizable().aspectRatio(contentMode: .fill)
                            .frame(height: 190).frame(maxWidth: .infinity).clipped()
                    }
                }
                .id(current?.id ?? "none")
                .transition(.push(from: stepDirection))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .offset(x: dragOffset)
                HStack {
                    stepButton("chevron.left") { step(-1, entries: entries, currentIndex: currentIndex) }
                    Spacer()
                    stepButton("chevron.right") { step(1, entries: entries, currentIndex: currentIndex) }
                }
                .padding(.horizontal, 6)
            }
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { drag in dragOffset = drag.translation.width * 0.4 }
                    .onEnded { drag in
                        withAnimation(.snappy(duration: 0.2)) { dragOffset = 0 }
                        if drag.translation.width < -50 {
                            step(1, entries: entries, currentIndex: currentIndex)
                        } else if drag.translation.width > 50 {
                            step(-1, entries: entries, currentIndex: currentIndex)
                        }
                    }
            )
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    if let folder = parts.folder {
                        Text(folder.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(parts.name)
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer()
                Text(currentIndex.map { "\($0 + 1) / \(entries.count)" } ?? "\(entries.count) looks")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func stepButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.45), in: Circle())
        }
        .buttonStyle(.plain)
    }

    /// Applies the neighbor of the current look (wrapping around). With nothing applied yet, the
    /// first step lands on the first (→) or last (←) look.
    private func step(_ delta: Int, entries: [LUTLibraryEntry], currentIndex: Int?) {
        guard !entries.isEmpty else { return }
        let target: Int
        if let currentIndex {
            target = (currentIndex + delta + entries.count) % entries.count
        } else {
            target = delta > 0 ? 0 : entries.count - 1
        }
        stepDirection = delta > 0 ? .trailing : .leading
        withAnimation(.snappy(duration: 0.3)) {
            actions.apply(entries[target])
        }
    }

    // MARK: Contact sheet

    private func contactSheet(entries: [LUTLibraryEntry]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 12) {
                noneTile
                ForEach(entries) { entry in
                    tile(entry)
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func tile(_ entry: LUTLibraryEntry) -> some View {
        let isSelected = entry.name == actions.currentTitle
        let parts = Self.split(entry)
        return VStack(alignment: .leading, spacing: 4) {
            LUTThumbnail(entry: entry, store: actions.store, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1.5)
                )
            VStack(alignment: .leading, spacing: 0) {
                Text(parts.name)
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .lineLimit(1)
                if let folder = parts.folder {
                    Text(folder).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            stepDirection = .trailing
            withAnimation(.snappy(duration: 0.3)) { actions.apply(entry) }
        }
    }

    /// "No look" — the photo as it is without a LUT.
    private var noneTile: some View {
        let isSelected = actions.currentTitle == nil
        return VStack(alignment: .leading, spacing: 4) {
            Group {
                if let base = actions.store.baseImage {
                    Image(decorative: base, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(Color.white.opacity(0.05))
                }
            }
            .frame(height: 80)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1.5)
            )
            Text("None")
                .font(.caption)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            stepDirection = .leading
            withAnimation(.snappy(duration: 0.3)) { actions.removeLUT() }
        }
    }

    /// "Kodak/Portra 400" → folder "Kodak", name "Portra 400" (see `LUTLibraryEntry.name`).
    private static func split(_ entry: LUTLibraryEntry) -> (folder: String?, name: String) {
        guard let slash = entry.name.lastIndex(of: "/") else { return (nil, entry.name) }
        return (String(entry.name[..<slash]), String(entry.name[entry.name.index(after: slash)...]))
    }
}
