import SwiftUI
import AppKit
import PhotoCatalog
import RawEngine

/// Candidate film-simulation (LUT) pickers, shown in `EditorSidebarView`'s Developer Mode
/// "Film Simulation Styles" panel. The problem they attack: a LUT's *name* says almost nothing about
/// what it will do to *this* photo, so the current text list means apply → look → undo → repeat.
/// Every concept here shows the open photo through the LUT before committing, and three of them
/// explore blending two looks (see `LUT3D.blend` — exact, and free at render time).
///
/// Blends are baked into the stage's single LUT slot when applied (the `Stage` model stores one
/// cube), so the A/B recipe itself only lives in these views' local state for now.

// MARK: - Preview store

/// Renders "this photo, before any LUT" once at thumbnail size (its own `RawImageRenderer`, so the
/// editor's cached decode and render loop are untouched), then runs LUTs over that small image for
/// previews. Parsed cubes and per-LUT thumbnails are cached. The base is a snapshot — refreshed
/// on demand (`prepareBase`), not live with every slider tick, which is fine for choosing a look.
@MainActor
@Observable
final class LUTPreviewStore {
    private(set) var baseImage: CGImage?
    private(set) var thumbnails: [String: CGImage] = [:]
    private var parsed: [String: LUT3D] = [:]
    private var pendingThumbnails: Set<String> = []
    private var baseGeneration = 0

    /// For hover-to-preview: the stage's LUT fields before the preview started, restored on exit.
    fileprivate var hoverSnapshot: StageLUTSnapshot?

    func prepareBase(url: URL, baseParams: RawBaseParameters, stageStack: [StageParameters]) {
        baseGeneration += 1
        let generation = baseGeneration
        thumbnails = [:]
        pendingThumbnails = []
        let stripped = stageStack.map { stage -> StageParameters in
            var copy = stage
            copy.lut3D = nil
            return copy
        }
        Task.detached(priority: .utility) { [weak self] in
            let renderer = RawImageRenderer()
            guard renderer.load(url: url) else { return }
            let image = renderer.renderPreview(baseParams: baseParams, stageStack: stripped, maxPixelSize: 360)
            await MainActor.run { [weak self] in
                guard let self, generation == self.baseGeneration else { return }
                self.baseImage = image
            }
        }
    }

    /// Parses (once) and returns the entry's cube.
    func lut(for entry: LUTLibraryEntry) async -> LUT3D? {
        if let cached = parsed[entry.id] { return cached }
        let url = entry.url
        let lut = await Task.detached(priority: .utility) { try? LUT3DLoader.load(contentsOf: url) }.value
        if let lut { parsed[entry.id] = lut }
        return lut
    }

    /// Kicks off (once per base image) the thumbnail for `entry`; the result lands in `thumbnails`.
    func requestThumbnail(for entry: LUTLibraryEntry) async {
        guard let base = baseImage, thumbnails[entry.id] == nil, !pendingThumbnails.contains(entry.id) else { return }
        pendingThumbnails.insert(entry.id)
        let generation = baseGeneration
        guard let lut = await lut(for: entry) else { return }
        let image = await Task.detached(priority: .utility) { LUT3DPreview.apply(lut, to: base) }.value
        guard generation == baseGeneration, let image else { return }
        thumbnails[entry.id] = image
    }

    /// The base image through an arbitrary (e.g. blended) LUT.
    func render(_ lut: LUT3D, intensity: Double = 1) async -> CGImage? {
        guard let base = baseImage else { return nil }
        return await Task.detached(priority: .userInitiated) { LUT3DPreview.apply(lut, intensity: intensity, to: base) }.value
    }
}

/// The four `Stage` fields a LUT occupies — captured for hover-preview restore.
fileprivate struct StageLUTSnapshot {
    var data: Data?
    var size: Int?
    var title: String?
    var enabled: Bool
    var intensity: Double?

    init(_ stage: Stage) {
        data = stage.lut3DData
        size = stage.lut3DSize
        title = stage.lut3DTitle
        enabled = stage.editLUT3DEnabled
        intensity = stage.lut3DIntensity
    }

    func restore(to stage: Stage) {
        stage.lut3DData = data
        stage.lut3DSize = size
        stage.lut3DTitle = title
        stage.editLUT3DEnabled = enabled
        stage.lut3DIntensity = intensity
    }
}

// MARK: - Actions

/// What every concept needs to act on the real edit: apply a (possibly blended) LUT to the selected
/// stage, preview one temporarily, and read/write intensity.
@MainActor
struct LUTConceptActions {
    let asset: PhotoAsset
    let stage: Stage
    let activeStages: [Stage]
    let coordinator: EditorRenderCoordinator
    let history: EditHistory
    let store: LUTPreviewStore

    var currentTitle: String? { stage.lut3DTitle }

    func apply(_ lut: LUT3D, title: String, intensity: Double? = nil) {
        store.hoverSnapshot = nil
        stage.lut3DData = lut.data
        stage.lut3DSize = lut.size
        stage.lut3DTitle = title
        stage.editLUT3DEnabled = true
        if let intensity { stage.lut3DIntensity = intensity }
        scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
    }

    /// Back to no LUT at all (same as the bottom bar's Film Simulation reset button).
    func removeLUT() {
        store.hoverSnapshot = nil
        resetLUT3D(stage)
        scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
    }

    func apply(_ entry: LUTLibraryEntry) {
        Task { @MainActor in
            guard let lut = await store.lut(for: entry) else { return }
            apply(lut, title: entry.name)
        }
    }

    /// Shows `entry` on the main preview without recording history; `endPreview` puts back what was
    /// there. Committing (`apply`) during a preview keeps the new LUT.
    func beginPreview(_ entry: LUTLibraryEntry) {
        Task { @MainActor in
            guard let lut = await store.lut(for: entry) else { return }
            if store.hoverSnapshot == nil { store.hoverSnapshot = StageLUTSnapshot(stage) }
            stage.lut3DData = lut.data
            stage.lut3DSize = lut.size
            stage.lut3DTitle = entry.name
            stage.editLUT3DEnabled = true
            scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator)
        }
    }

    func endPreview() {
        guard let snapshot = store.hoverSnapshot else { return }
        store.hoverSnapshot = nil
        snapshot.restore(to: stage)
        scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator)
    }

    var intensity: Binding<Double> {
        Binding(
            get: { stage.lut3DIntensity ?? 1 },
            set: { newValue in
                stage.lut3DIntensity = newValue
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            }
        )
    }
}

// MARK: - Shared pieces

/// The photo through one LUT, or a placeholder while it renders.
struct LUTThumbnail: View {
    let entry: LUTLibraryEntry
    let store: LUTPreviewStore
    var height: CGFloat = 64

    var body: some View {
        Group {
            if let image = store.thumbnails[entry.id] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.white.opacity(0.05))
                    .overlay(ProgressView().controlSize(.mini))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipped()
        .task(id: store.baseImage.map { ObjectIdentifier($0) }) {
            await store.requestThumbnail(for: entry)
        }
    }
}

/// A plain rendered preview image with rounded corners (for blends).
private struct PreviewImage: View {
    let image: CGImage?
    var height: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color.white.opacity(0.05))
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Menu that picks one library entry, labeled with the current pick.
private struct LUTSlotPicker: View {
    let label: String
    let entries: [LUTLibraryEntry]
    @Binding var selection: LUTLibraryEntry?

    var body: some View {
        Menu {
            ForEach(entries) { entry in
                Button(entry.name) { selection = entry }
            }
        } label: {
            HStack(spacing: 4) {
                Text(label).font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                Text(selection?.name ?? "Choose…").font(.caption).lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }
}

func emptyLibraryNote(_ library: LUTLibrary) -> some View {
    Text(library.folderURL == nil ? "No LUT folder set (Settings › LUTs)" : "No LUTs in folder")
        .font(.caption)
        .foregroundStyle(.secondary)
}

// MARK: - 1. Contact Sheet

/// Every LUT as a small copy of *this photo* in a grid — pick by look, not by name. The most direct
/// answer to "which one do I want?".
struct LUTContactSheet: View {
    let actions: LUTConceptActions
    @Environment(LUTLibrary.self) private var library
    @Environment(ColorSchemeStore.self) private var uiColors

    var body: some View {
        let entries = library.visibleEntries
        if entries.isEmpty {
            emptyLibraryNote(library)
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 10) {
                ForEach(entries) { entry in
                    let isSelected = entry.name == actions.currentTitle
                    VStack(spacing: 4) {
                        LUTThumbnail(entry: entry, store: actions.store, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .strokeBorder(isSelected ? Color.white : Color.clear, lineWidth: 1.5)
                            )
                        Text(entry.name)
                            .font(.system(size: 9))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { actions.apply(entry) }
                }
            }
        }
    }
}

// MARK: - 2. Hover Preview List

/// Today's list, plus: hovering a row shows that LUT on the *main* image immediately (no history
/// entry), moving off restores what was there, clicking keeps it. Browsing becomes sweeping the
/// cursor down the list while watching the photo — no apply/undo loop.
struct LUTHoverPreviewList: View {
    let actions: LUTConceptActions
    @Environment(LUTLibrary.self) private var library
    @State private var hovered: String?

    var body: some View {
        let entries = library.visibleEntries
        if entries.isEmpty {
            emptyLibraryNote(library)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { entry in
                    let isSelected = entry.name == actions.currentTitle && actions.store.hoverSnapshot == nil
                    HStack(spacing: 8) {
                        LUTThumbnail(entry: entry, store: actions.store, height: 22)
                            .frame(width: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        Text(entry.name)
                            .font(.caption)
                            .foregroundStyle(isSelected || hovered == entry.id ? Color.primary : Color.secondary)
                            .lineLimit(1)
                        Spacer()
                        if hovered == entry.id {
                            Text("previewing").font(.system(size: 8)).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        isSelected ? Color.primary.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside {
                            hovered = entry.id
                            actions.beginPreview(entry)
                        } else if hovered == entry.id {
                            hovered = nil
                        }
                    }
                    .onTapGesture {
                        hovered = nil
                        actions.apply(entry)
                    }
                }
            }
            // Leaving the list as a whole (not just moving between rows) restores the original.
            .onHover { inside in
                if !inside {
                    hovered = nil
                    actions.endPreview()
                }
            }
        }
    }
}

// MARK: - 3. Filmstrip + Strength

/// A horizontal strip of looks with the selected one's strength right under it — choosing a look
/// and dialing how much of it are one gesture area, since in practice they're always done together.
struct LUTFilmstripStrength: View {
    let actions: LUTConceptActions
    @Environment(LUTLibrary.self) private var library

    var body: some View {
        let entries = library.visibleEntries
        if entries.isEmpty {
            emptyLibraryNote(library)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(entries) { entry in
                            let isSelected = entry.name == actions.currentTitle
                            VStack(spacing: 3) {
                                LUTThumbnail(entry: entry, store: actions.store, height: isSelected ? 70 : 54)
                                    .frame(width: isSelected ? 92 : 70)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                Text(entry.name)
                                    .font(.system(size: 9))
                                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                    .lineLimit(1)
                                    .frame(width: isSelected ? 92 : 70)
                            }
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation(.snappy(duration: 0.2)) { actions.apply(entry) } }
                        }
                    }
                }
                .frame(height: 88)
                if actions.currentTitle != nil {
                    slider("Strength", value: actions.intensity, range: 0...1, resetValue: 1,
                           ticks: [0, 0.25, 0.5, 0.75, 1], trackStyle: .hairline, thumbShape: .diamond)
                }
            }
        }
    }
}

// MARK: - 4. Crossfade A ↔ B

/// Two looks, one fader between them. The middle preview is the actual blend, and it's live — the
/// main image follows the fader. For "I like the greens of this one and the skin of that one".
struct LUTCrossfade: View {
    let actions: LUTConceptActions
    @Environment(LUTLibrary.self) private var library
    @State private var a: LUTLibraryEntry?
    @State private var b: LUTLibraryEntry?
    @State private var mix = 0.5
    @State private var blendPreview: CGImage?
    /// Nothing is written to the photo until the user actually touches this concept — merely
    /// showing the dev panel must never replace their LUT.
    @State private var hasInteracted = false

    private func touching<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; hasInteracted = true })
    }

    var body: some View {
        let entries = library.visibleEntries
        if entries.count < 2 {
            emptyLibraryNote(library)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    slot(a, label: "A")
                    PreviewImage(image: blendPreview, height: 64)
                        .overlay(alignment: .bottom) {
                            Text("\(Int((1 - mix) * 100))% A · \(Int(mix * 100))% B")
                                .font(.system(size: 8, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(.black.opacity(0.5), in: Capsule())
                                .padding(4)
                        }
                    slot(b, label: "B")
                }
                HStack {
                    LUTSlotPicker(label: "A", entries: entries, selection: touching($a))
                    Spacer()
                    LUTSlotPicker(label: "B", entries: entries, selection: touching($b))
                }
                slider("A ⟷ B", value: touching($mix), range: 0...1, resetValue: 0.5, ticks: [0, 0.5, 1], trackStyle: .hairline, thumbShape: .diamond)
            }
            .onAppear {
                if a == nil { a = entries.first }
                if b == nil { b = entries.dropFirst().first }
            }
            .task(id: "\(a?.id ?? "")|\(b?.id ?? "")|\(mix)|\(actions.store.baseImage.map { ObjectIdentifier($0).hashValue } ?? 0)") {
                await applyBlend()
            }
        }
    }

    private func slot(_ entry: LUTLibraryEntry?, label: String) -> some View {
        VStack(spacing: 3) {
            if let entry {
                LUTThumbnail(entry: entry, store: actions.store, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05)).frame(height: 44)
            }
            Text(label).font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
        }
        .frame(width: 60)
    }

    private func applyBlend() async {
        guard let a, let b,
              let lutA = await actions.store.lut(for: a),
              let lutB = await actions.store.lut(for: b) else { return }
        let blended = LUT3D.blend(lutA, lutB, t: mix)
        blendPreview = await actions.store.render(blended)
        guard hasInteracted else { return }
        actions.apply(blended, title: "\(a.name) ⟷ \(b.name) \(Int(mix * 100))%")
    }
}

// MARK: - 5. Blend Pad

/// A 2D pad: left↔right blends look A into look B, bottom↔top goes from the original photo to the
/// full look. One drag explores both "which" and "how much" at once; corner previews show the
/// extremes so you know where you're heading.
struct LUTBlendPad: View {
    let actions: LUTConceptActions
    @Environment(LUTLibrary.self) private var library
    @Environment(ColorSchemeStore.self) private var uiColors
    @State private var a: LUTLibraryEntry?
    @State private var b: LUTLibraryEntry?
    @State private var point = CGPoint(x: 0.5, y: 0.8)
    /// See `LUTCrossfade.hasInteracted`.
    @State private var hasInteracted = false

    private func touching(_ binding: Binding<LUTLibraryEntry?>) -> Binding<LUTLibraryEntry?> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; hasInteracted = true })
    }

    var body: some View {
        let entries = library.visibleEntries
        if entries.count < 2 {
            emptyLibraryNote(library)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    LUTSlotPicker(label: "A", entries: entries, selection: touching($a))
                    Spacer()
                    LUTSlotPicker(label: "B", entries: entries, selection: touching($b))
                }
                GeometryReader { geo in
                    let size = geo.size
                    ZStack {
                        RoundedRectangle(cornerRadius: 8).fill(uiColors.recessedTrackBackground)
                        // Corner previews: A top-left, B top-right, the untouched photo along the bottom.
                        VStack {
                            HStack {
                                corner(a).frame(width: 64, height: 40)
                                Spacer()
                                corner(b).frame(width: 64, height: 40)
                            }
                            Spacer()
                            PreviewImage(image: actions.store.baseImage, height: 28)
                                .frame(width: 64)
                                .opacity(0.8)
                        }
                        .padding(6)
                        Text("Original").font(.system(size: 8)).foregroundStyle(.tertiary)
                            .frame(maxHeight: .infinity, alignment: .bottom).offset(y: -38)
                        Circle()
                            .fill(.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                            .position(x: point.x * size.width, y: (1 - point.y) * size.height)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        hasInteracted = true
                        point = CGPoint(
                            x: min(max(drag.location.x / size.width, 0), 1),
                            y: min(max(1 - drag.location.y / size.height, 0), 1)
                        )
                    })
                }
                .frame(height: 150)
                Text("← A · B →   ↓ original · full look ↑")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .onAppear {
                if a == nil { a = entries.first }
                if b == nil { b = entries.dropFirst().first }
            }
            .task(id: "\(a?.id ?? "")|\(b?.id ?? "")|\(point.x)|\(point.y)") {
                guard hasInteracted, let a, let b,
                      let lutA = await actions.store.lut(for: a),
                      let lutB = await actions.store.lut(for: b) else { return }
                let blended = LUT3D.blend(lutA, lutB, t: point.x)
                actions.apply(blended, title: "\(a.name) ⟷ \(b.name)", intensity: point.y)
            }
        }
    }

    private func corner(_ entry: LUTLibraryEntry?) -> some View {
        Group {
            if let entry {
                LUTThumbnail(entry: entry, store: actions.store, height: 40)
            } else {
                Rectangle().fill(Color.white.opacity(0.05))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

// MARK: - 6. Split Compare

/// Two looks side by side on one preview, with a draggable divider — the decision between two
/// finalists, made by comparing the same pixels. Then keep A, keep B, or split the difference.
struct LUTSplitCompare: View {
    let actions: LUTConceptActions
    @Environment(LUTLibrary.self) private var library
    @State private var a: LUTLibraryEntry?
    @State private var b: LUTLibraryEntry?
    @State private var split = 0.5

    var body: some View {
        let entries = library.visibleEntries
        if entries.count < 2 {
            emptyLibraryNote(library)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    LUTSlotPicker(label: "A", entries: entries, selection: $a)
                    Spacer()
                    LUTSlotPicker(label: "B", entries: entries, selection: $b)
                }
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        if let b { LUTThumbnail(entry: b, store: actions.store, height: geo.size.height) }
                        if let a {
                            LUTThumbnail(entry: a, store: actions.store, height: geo.size.height)
                                .mask(alignment: .leading) { Rectangle().frame(width: split * w) }
                        }
                        Rectangle().fill(.white).frame(width: 1.5).offset(x: split * w - 0.75)
                        Text("A").font(.caption2.weight(.bold)).padding(5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        Text("B").font(.caption2.weight(.bold)).padding(5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                        split = min(max(drag.location.x / w, 0), 1)
                    })
                }
                .frame(height: 130)
                HStack(spacing: 8) {
                    choice("Use A") { if let a { actions.apply(a) } }
                    choice("50 / 50") {
                        Task { @MainActor in
                            guard let a, let b,
                                  let lutA = await actions.store.lut(for: a),
                                  let lutB = await actions.store.lut(for: b) else { return }
                            actions.apply(LUT3D.blend(lutA, lutB, t: 0.5), title: "\(a.name) ⟷ \(b.name) 50%")
                        }
                    }
                    choice("Use B") { if let b { actions.apply(b) } }
                }
            }
            .onAppear {
                if a == nil { a = entries.first }
                if b == nil { b = entries.dropFirst().first }
            }
        }
    }

    private func choice(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 7. Film Roll Shuffle

/// Deliberately off-brand for this app's flat, restrained UI (a skeuomorphic toy, tried on request):
/// each LUT is a 35mm film canister with its leader pulled out, the strip showing *this photo*
/// through that look. Drag sideways (or use ‹ ›) to shuffle the rolls past in a cover-flow row;
/// whichever roll settles in the middle gets loaded.
struct LUTFilmRollShuffle: View {
    let actions: LUTConceptActions
    @Environment(LUTLibrary.self) private var library
    @State private var index = 0
    @State private var dragShift: CGFloat = 0

    private let spacing: CGFloat = 92

    var body: some View {
        let entries = library.visibleEntries
        if entries.isEmpty {
            emptyLibraryNote(library)
        } else {
            VStack(spacing: 10) {
                ZStack {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                        let position = CGFloat(i - index) + dragShift
                        if abs(position) < 3.5 {
                            FilmRoll(entry: entry, store: actions.store, isLoaded: entry.name == actions.currentTitle)
                                .scaleEffect(1 - min(abs(position), 3) * 0.14)
                                .rotation3DEffect(.degrees(Double(-position) * 28), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                                .offset(x: position * spacing)
                                .opacity(1 - Double(min(abs(position), 3)) * 0.25)
                                .zIndex(-Double(abs(position)))
                                .onTapGesture { shuffle(to: i, count: entries.count, entries: entries) }
                        }
                    }
                }
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { drag in dragShift = drag.translation.width / spacing }
                        .onEnded { drag in
                            let target = index - Int((drag.translation.width / spacing).rounded())
                            shuffle(to: target, count: entries.count, entries: entries)
                        }
                )
                HStack {
                    arrow("chevron.left") { shuffle(to: index - 1, count: entries.count, entries: entries) }
                    Spacer()
                    VStack(spacing: 1) {
                        Text(entries[min(index, entries.count - 1)].name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(entries[min(index, entries.count - 1)].name == actions.currentTitle ? "Loaded" : "\(index + 1) of \(entries.count)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    arrow("chevron.right") { shuffle(to: index + 1, count: entries.count, entries: entries) }
                }
            }
            .onAppear {
                if let current = entries.firstIndex(where: { $0.name == actions.currentTitle }) { index = current }
            }
        }
    }

    private func shuffle(to target: Int, count: Int, entries: [LUTLibraryEntry]) {
        let clamped = min(max(target, 0), count - 1)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
            index = clamped
            dragShift = 0
        }
        actions.apply(entries[clamped])
    }

    private func arrow(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One 35mm canister: ribbed metal shell with dark end caps and a printed label band in a color
/// derived from the LUT's name, plus the film leader pulled out to the side — sprocket-holed strip
/// with the photo-through-this-LUT in its frame.
private struct FilmRoll: View {
    let entry: LUTLibraryEntry
    let store: LUTPreviewStore
    let isLoaded: Bool

    /// Stable per-name label color (not `hashValue`, which is randomized per launch).
    private var labelColor: Color {
        let seed = entry.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return Color(hue: Double(seed % 360) / 360, saturation: 0.65, brightness: 0.8)
    }

    var body: some View {
        HStack(spacing: -4) {
            canister.zIndex(1)
            leader
        }
        .shadow(color: .black.opacity(0.5), radius: 6, y: 4)
        .overlay(alignment: .bottom) {
            if isLoaded {
                Capsule().fill(.white).frame(width: 18, height: 3).offset(y: 10)
            }
        }
    }

    private var canister: some View {
        VStack(spacing: 0) {
            // Top cap + spool nub.
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.12)).frame(width: 46, height: 8)
                RoundedRectangle(cornerRadius: 1.5).fill(Color(white: 0.25)).frame(width: 14, height: 6).offset(y: -6)
            }
            // Shell with the label band.
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.35), Color(white: 0.75), Color(white: 0.5), Color(white: 0.28)],
                    startPoint: .leading, endPoint: .trailing
                )
                VStack(spacing: 0) {
                    Rectangle().fill(labelColor).frame(height: 30)
                    Rectangle().fill(Color.black.opacity(0.75)).frame(height: 14)
                        .overlay(
                            Text("ISO 400").font(.system(size: 6, weight: .heavy)).foregroundStyle(labelColor)
                        )
                    Rectangle().fill(labelColor.opacity(0.85)).frame(height: 18)
                }
                .overlay(
                    LinearGradient(
                        colors: [.black.opacity(0.35), .white.opacity(0.25), .clear, .black.opacity(0.4)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                Text(entry.name.uppercased())
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .frame(width: 40)
                    .offset(y: -8)
                    .shadow(color: .black.opacity(0.4), radius: 0.5)
            }
            .frame(width: 42, height: 70)
            RoundedRectangle(cornerRadius: 3).fill(Color(white: 0.12)).frame(width: 46, height: 8)
        }
    }

    private var leader: some View {
        VStack(spacing: 3) {
            sprockets
            LUTThumbnail(entry: entry, store: store, height: 40)
                .frame(width: 58)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
            sprockets
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(Color(red: 0.16, green: 0.11, blue: 0.07))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0, bottomTrailingRadius: 8, topTrailingRadius: 3))
    }

    private var sprockets: some View {
        HStack(spacing: 4) {
            ForEach(0..<6, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1).fill(Color(white: 0.85).opacity(0.8)).frame(width: 5, height: 4)
            }
        }
    }
}
