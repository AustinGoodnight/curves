import SwiftUI
import AppKit
import SwiftData
import PhotoCatalog
import RawEngine
import CoreImage

/// Assembles the image pane, `EditorSidebarView`, and `ColorBalanceBarView` — deliberately thin.
/// Those two are genuine separate `View` types (not computed properties) specifically so that
/// dragging a control in one doesn't force SwiftUI to re-diff the other; see
/// `EditorRenderCoordinator`'s doc comment for the full story on why that split exists.
struct EditorView: View {
    let asset: PhotoAsset
    /// Threaded down to `StagesSidebarView`'s "Stack" section, which also lets you jump to a
    /// different photo without leaving the editor (`SessionFilmstripView`, `ContentView`'s other
    /// consumer of this same closure, is constructed as this view's sibling rather than its child —
    /// see that view's doc comment). `ContentView` passes its own `openEditor(for:)` here, the same
    /// function the grid uses, so switching photos from either filmstrip behaves identically to
    /// opening one from the grid.
    var onSelectAsset: (PhotoAsset) -> Void

    @State private var coordinator = EditorRenderCoordinator()
    @Environment(ColorSchemeStore.self) private var uiColors
    /// Cmd+Z/Cmd+Shift+Z undo/redo for value-level edits — see `EditHistory`'s doc comment for
    /// scope. Seeded in `init` with this asset's starting values so the very first edit diffs
    /// against the right baseline, and re-seeded in the `.task(id:)` below on every photo switch.
    @State private var history: EditHistory
    /// Which stage's own values the controls currently show ("blank slate" editing — see
    /// `Stage`'s doc comment). Never affects what's rendered; the preview always composites
    /// `activeStages` regardless of this selection.
    @State private var selectedStage: Stage
    /// The Scene/Single/Custom stages currently contributing to the composite, cached rather than
    /// recomputed via `activeStageStack(for:)` on every render — that walks the asset's `scene`/
    /// `stages` relationships, which is real, measurable work when it runs on every single slider-
    /// drag tick. Refreshed explicitly (`refreshActiveStages()`) only when stage membership itself
    /// changes: add/delete/enable-toggle. Editing a stage's own field values doesn't need a
    /// refresh — those still read fresh off the `Stage` objects already in this array.
    @State private var activeStages: [Stage]
    /// Set while the assisted-mask editor is open for a stage — replaces the plain preview `Image`
    /// in the image pane with `AssistedMaskEditorOverlay` for that stage. `nil` the rest of the
    /// time; never affects what's rendered on its own (only writing `stage.maskData` via the
    /// overlay's "Done" button does that).
    @State private var maskEditingStage: Stage?
    /// Set while `GradientMaskEditorOverlay` is open for a `.linearGradientMask`/
    /// `.radialGradientMask` stage — same role as `maskEditingStage`, just for the gradient-handle
    /// editor instead of the brush one; the two are mutually exclusive in practice since only one
    /// "Edit"/"Adjust" action can be in flight at a time.
    @State private var gradientEditingStage: Stage?
    /// Set while `ColorRangeMaskEditorOverlay` is open for a `.colorRangeMask` stage — same role as
    /// `gradientEditingStage`, just for the color-sampling editor instead.
    @State private var colorRangeEditingStage: Stage?
    /// Set while `ObjectMaskEditorOverlay` is open for a `.objectMask` stage — same role as
    /// `colorRangeEditingStage`, just for the Vision object-selection editor instead.
    @State private var objectMaskEditingStage: Stage?
    /// Set while `CropEditorOverlay` is open — same role as `gradientEditingStage`, just asset-level
    /// (crop/straighten isn't per-`Stage`, see `CropParameters`'s doc comment) so a plain `Bool`
    /// rather than an optional `Stage`.
    @State private var cropEditing = false
    /// Set while `SpotRemovalEditorOverlay` is open — same role as `cropEditing`, just for
    /// blemish/dust-spot healing instead of crop (also asset-level, see `SpotRemoval`'s doc comment
    /// on `RawEngine`).
    @State private var spotRemovalEditing = false
    /// Set while `RemoveObjectEditorOverlay` is open — same role as `spotRemovalEditing`, just for
    /// Vision-selected + AI-generated object removal instead of manual clone/heal (also
    /// asset-level, see `ObjectRemoval`'s doc comment on `RawEngine`).
    @State private var objectRemovalEditing = false
    /// Set while `PaintedFillEditorOverlay` is open — same role as `objectRemovalEditing`, just for
    /// a hand-painted mask instead of Vision's click-to-select; both write the same
    /// `asset.objectRemovalData` list.
    @State private var paintedFillEditing = false
    /// Which of `previewBackgroundPalette` the preview pane's backdrop currently shows — purely a
    /// viewing aid (checking how the image reads against different surrounds), not part of the
    /// edit itself, so this is plain local `@State`, not persisted or threaded into `scheduleRender`.
    @State private var previewBackgroundColor: Color = .editorPreviewBackground
    /// Set from `StagesSidebarView`'s "Stack" section "eye" button — swaps the main preview to a
    /// plain, unedited decode of *this* stacked JPG (see `jpgPreviewImage`) instead of `asset`'s own
    /// `coordinator.previewImage`, without navigating the editor away from `asset`'s own open edit
    /// session the way `onSelectAsset` would. `nil` is the normal state (showing `asset`'s own
    /// preview); set back to `nil` by the comparison view's own "Back to RAW" button.
    @State private var jpgPreviewAsset: PhotoAsset?
    /// The plain decode `jpgPreviewAsset` produces — `nil` while decoding (or if `jpgPreviewAsset`
    /// itself is `nil`). Deliberately *not* run through `coordinator`/`RawImageRenderer`'s normal
    /// `renderPreview`: that always composites `stageStack` over whatever it decodes, and a stacked
    /// JPG shares the open RAW's `singleStage`/`customStages` (see `PhotoStack.stages`'s doc
    /// comment in `PhotoCatalog`), so going through the normal pipeline would apply the RAW's own
    /// Filmic/Color Balance/Curve/etc. edits on top of the JPG — the opposite of "no edits applied".
    /// A direct `CIImage(contentsOf:)` decode, mirroring `RawImageRenderer.load(url:)`'s own
    /// standard-image fallback, is what actually guarantees that.
    @State private var jpgPreviewImage: CGImage?

    init(asset: PhotoAsset, onSelectAsset: @escaping (PhotoAsset) -> Void) {
        self.asset = asset
        self.onSelectAsset = onSelectAsset
        let single = asset.singleStage
        _selectedStage = State(initialValue: single)
        let stages = activeStageStack(for: asset)
        _activeStages = State(initialValue: stages)
        let history = EditHistory()
        history.reset(asset: asset, activeStages: stages)
        _history = State(initialValue: history)
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                StagesSidebarView(
                    asset: asset, selectedStage: $selectedStage, activeStages: $activeStages, coordinator: coordinator,
                    history: history,
                    onSelectAsset: onSelectAsset,
                    onPreviewJPG: { jpgPreviewAsset = $0 },
                    onEditMask: { maskEditingStage = $0 },
                    onEditGradientMask: { gradientEditingStage = $0 },
                    onEditColorRangeMask: { colorRangeEditingStage = $0 },
                    onEditObjectMask: { objectMaskEditingStage = $0 }
                )
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 280)

                ZStack {
                    previewBackgroundColor
                    if let maskEditingStage, let previewImage = coordinator.previewImage {
                        AssistedMaskEditorOverlay(
                            stage: maskEditingStage,
                            previewImage: previewImage,
                            onFinished: {
                                self.maskEditingStage = nil
                                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                            }
                        )
                    } else if let gradientEditingStage, let previewImage = coordinator.previewImage {
                        GradientMaskEditorOverlay(
                            stage: gradientEditingStage,
                            previewImage: previewImage,
                            onFinished: {
                                self.gradientEditingStage = nil
                                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                            }
                        )
                    } else if let colorRangeEditingStage, let previewImage = coordinator.previewImage {
                        ColorRangeMaskEditorOverlay(
                            stage: colorRangeEditingStage,
                            previewImage: previewImage,
                            onFinished: {
                                self.colorRangeEditingStage = nil
                                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                            }
                        )
                    } else if let objectMaskEditingStage, let previewImage = coordinator.previewImage {
                        ObjectMaskEditorOverlay(
                            stage: objectMaskEditingStage,
                            previewImage: previewImage,
                            onFinished: {
                                self.objectMaskEditingStage = nil
                                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                            }
                        )
                    } else if paintedFillEditing, coordinator.isReady {
                        PaintedFillEditorOverlay(
                            asset: asset,
                            activeStages: activeStages,
                            coordinator: coordinator,
                            onFinished: {
                                paintedFillEditing = false
                                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                            }
                        )
                    } else if cropEditing, coordinator.isReady {
                        CropEditorOverlay(
                            asset: asset,
                            activeStages: activeStages,
                            coordinator: coordinator,
                            onFinished: {
                                cropEditing = false
                                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                            }
                        )
                    } else if spotRemovalEditing, coordinator.isReady {
                        SpotRemovalEditorOverlay(
                            asset: asset,
                            activeStages: activeStages,
                            coordinator: coordinator,
                            onFinished: {
                                spotRemovalEditing = false
                                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                            }
                        )
                    } else if objectRemovalEditing, coordinator.isReady {
                        RemoveObjectEditorOverlay(
                            asset: asset,
                            activeStages: activeStages,
                            coordinator: coordinator,
                            onFinished: {
                                objectRemovalEditing = false
                                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                            }
                        )
                    } else if let jpgPreviewAsset {
                        ZStack {
                            if let jpgPreviewImage {
                                ZoomableImagePane(previewImage: jpgPreviewImage)
                                    .id(jpgPreviewAsset.filePath)
                            } else {
                                ProgressView("Decoding JPG…")
                                    .tint(.white)
                                    .foregroundStyle(.white)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            HStack(spacing: 10) {
                                Text("\(jpgPreviewAsset.fileName) — no edits applied")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                Button("Back to RAW") { self.jpgPreviewAsset = nil }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.white)
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                            .padding(.bottom, 16)
                        }
                    } else if let previewImage = coordinator.previewImage {
                        ZoomableImagePane(previewImage: previewImage)
                            .id(asset.filePath)
                    } else {
                        ProgressView("Decoding RAW…")
                            .tint(.white)
                            .foregroundStyle(.white)
                    }
                }
                .frame(minWidth: 480, minHeight: 400)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .top) { previewOverlayToolbar }

                EditorSidebarView(asset: asset, stage: selectedStage, activeStages: activeStages, coordinator: coordinator, history: history)
            }

            // The `HSplitView` above and `ColorBalanceBarView` below both sit on the same
            // `sidebarBackground` fill, so without a seam here the bottom bar reads as a
            // continuation of the sidebars above it rather than its own region. Safe to add back
            // now — `ColorBalanceBarView.body`'s `.fixedSize(vertical:)` guard (see its own doc
            // comment) is exactly the insurance put in place for this.
            Divider()

            ColorBalanceBarView(
                asset: asset, stage: selectedStage, activeStages: activeStages, coordinator: coordinator, history: history,
                wheelDiameter: wheelDiameter
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset.filePath) {
            history.reset(asset: asset, activeStages: activeStages)
            history.onRestore = {
                coordinator.scheduleRender(
                    baseParams: rawBaseParameters(for: asset),
                    stageStack: activeStages.map { stageParameters(for: $0, detailEnabled: asset.editDetailEnabled) }
                )
            }
            await coordinator.loadAndRender(
                url: asset.resolvedURL(),
                baseParams: rawBaseParameters(for: asset),
                stageStack: activeStages.map { stageParameters(for: $0, detailEnabled: asset.editDetailEnabled) }
            )
        }
        // Keyed on the id, not `jpgPreviewAsset` itself — `PhotoAsset`'s own `Equatable` is
        // identity-based (see `DetailStore`'s doc comment elsewhere in this app), so this would
        // behave the same either way, but the id makes the "what actually changes this" intent
        // explicit. A direct `CIImage(contentsOf:)` decode, not `coordinator`/`RawImageRenderer` —
        // see `jpgPreviewImage`'s doc comment for why going through the normal render pipeline
        // would apply the open RAW's own edits on top of the JPG instead of showing it plain.
        .task(id: jpgPreviewAsset?.id) {
            guard let jpgPreviewAsset else {
                jpgPreviewImage = nil
                return
            }
            let url = jpgPreviewAsset.resolvedURL()
            jpgPreviewImage = await Task.detached(priority: .userInitiated) {
                guard let ciImage = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
                return CIContext().createCGImage(ciImage, from: ciImage.extent)
            }.value
        }
        // Flushes any edit still sitting in `history`'s 400ms debounce window when the editor
        // closes — see `EditHistory.flush()`'s doc comment for why an unflushed pending write would
        // otherwise be silently lost along with this view's `@State`.
        .onDisappear {
            history.flush()
        }
    }

    /// Micro toolbar floating on the preview pane's own background, centered above the image —
    /// groups the two "how am I viewing this" controls that aren't part of any `Stage`'s edit
    /// values: crop/straighten (asset-level, see `cropEditing`'s doc comment) and the preview
    /// backdrop swatches. Deliberately an overlay on the `ZStack`'s background rather than a real
    /// toolbar row (which would take layout space above the image and shrink it) — `.thinMaterial`
    /// matches this file's other floating chrome (the zoom-percent pill in `ZoomableImagePane`).
    private var previewOverlayToolbar: some View {
        HStack(spacing: 10) {
            Button {
                cropEditing = true
            } label: {
                Image(systemName: "crop.rotate")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(cropHasAdjustments(asset) ? uiColors.accentColor : .primary)
            .help(cropHasAdjustments(asset) ? "Adjust Crop & Straighten…" : "Crop & Straighten…")

            Button {
                spotRemovalEditing = true
            } label: {
                Image(systemName: "bandage")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(spotRemovalHasAdjustments(asset) ? uiColors.accentColor : .primary)
            .help(spotRemovalHasAdjustments(asset) ? "Adjust Spot Removal…" : "Spot Removal…")

            Button {
                objectRemovalEditing = true
            } label: {
                Image(systemName: "wand.and.sparkles")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(objectRemovalHasAdjustments(asset) ? uiColors.accentColor : .primary)
            .help(objectRemovalHasAdjustments(asset) ? "Adjust Remove Object…" : "Remove Object (AI)…")

            Button {
                paintedFillEditing = true
            } label: {
                Image(systemName: "paintbrush.pointed.fill")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .foregroundStyle(objectRemovalHasAdjustments(asset) ? uiColors.accentColor : .primary)
            .help(objectRemovalHasAdjustments(asset) ? "Adjust AI Fill (Painted Mask)…" : "AI Fill (Painted Mask)…")

            Divider().frame(height: 16)

            previewBackgroundPaletteRow
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 10)
    }

    /// Small clickable swatches, part of `previewOverlayToolbar` — tapping one sets
    /// `previewBackgroundColor`; the currently-active swatch gets an accent-colored ring so it's
    /// clear which surround is showing. The 6 swatches themselves
    /// (`uiColors.previewBackgroundPalette`) are user-customizable in Settings — a small fixed
    /// spread from black to white by default rather than a full color picker here, since the point
    /// is judging exposure/contrast against different *neutral* surrounds (the same reason
    /// `editorPreviewBackground` itself isn't pure black — see its own doc comment), not decorating
    /// the workspace.
    private var previewBackgroundPaletteRow: some View {
        HStack(spacing: 6) {
            ForEach(uiColors.previewBackgroundPalette.indices, id: \.self) { i in
                let color = uiColors.previewBackgroundPalette[i]
                Button {
                    previewBackgroundColor = color
                } label: {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: 18, height: 18)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(
                                    previewBackgroundColor == color ? uiColors.accentColor : Color.white.opacity(0.25),
                                    lineWidth: previewBackgroundColor == color ? 2 : 1
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Sized so the puck circle's own *bottom edge* lands at the same height as the fader bar's
    /// bottom edge, not so either the circle's diameter or its container's full bounding box
    /// (`ColorWheelControl.containerSize` = diameter + 52pt) matches `colorFaderTrackHeight`
    /// outright — both of those undershoot/overshoot by the same 26pt, since the circle sits
    /// centered in its container with a fixed 26pt margin above and below regardless of diameter
    /// (`(containerSize - diameter) / 2`, and `containerSize` is defined as `diameter + 52`).
    /// The circle's bottom edge, measured from its container's top, is `26 + diameter`; setting
    /// that equal to `colorFaderTrackHeight` gives `diameter = colorFaderTrackHeight - 26`.
    private var wheelDiameter: CGFloat {
        colorFaderTrackHeight - 26
    }
}

/// Pinch-to-zoom / drag-to-pan / double-click-to-toggle for the editor's main preview image. A
/// separate `View` type (not inline in `EditorView.body`) specifically so `zoomScale`/`panOffset`
/// live as `@State` on the smallest view that needs them — per this project's documented
/// "frequently-mutated state living on the wrong view" trap, a pan drag mutating `@State` declared
/// directly on `EditorView` would invalidate all of `EditorView.body` (filmstrip, both sidebars,
/// color balance bar) on every drag tick. `previewImage` itself changes on every render tick
/// (including mid-slider-drag draft renders) — zoom/pan state must *not* reset on that, only on
/// switching to a different photo, which the call site handles via `.id(asset.filePath)`.
private struct ZoomableImagePane: View {
    let previewImage: CGImage

    @State private var zoomScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var gesturePanOffset: CGSize = .zero

    private let minZoom: CGFloat = 1
    private let maxZoom: CGFloat = 8
    private let doubleClickZoom: CGFloat = 2.5

    private var imageSize: CGSize {
        CGSize(width: previewImage.width, height: previewImage.height)
    }

    var body: some View {
        GeometryReader { geometry in
            let baseFitRect = Self.aspectFitRect(imageSize: imageSize, in: geometry.size)
            ZStack {
                Image(decorative: previewImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(zoomScale)
                    .offset(
                        x: panOffset.width + gesturePanOffset.width,
                        y: panOffset.height + gesturePanOffset.height
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                gesturePanOffset = value.translation
                            }
                            .onEnded { value in
                                panOffset = clampedPan(
                                    CGSize(width: panOffset.width + value.translation.width, height: panOffset.height + value.translation.height),
                                    zoom: zoomScale, containerSize: geometry.size
                                )
                                gesturePanOffset = .zero
                            }
                    )
                    .simultaneousGesture(
                        SpatialTapGesture(count: 2)
                            .onEnded { value in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if zoomScale > minZoom + 0.01 {
                                        zoomScale = minZoom
                                        panOffset = .zero
                                    } else {
                                        setZoom(doubleClickZoom, anchor: value.location, baseFitRect: baseFitRect, containerSize: geometry.size)
                                    }
                                }
                            }
                    )

                // Pinch (`NSEvent.magnify` via `MagnifyCatcher`, not SwiftUI's `MagnificationGesture`
                // — that gesture reports only a scale factor with no location, so it can't anchor the
                // zoom on the cursor) — same approach as `ZoomPanState`'s overlay editors, see its doc
                // comment for why.
                MagnifyCatcher { delta, location in
                    setZoom(zoomScale * (1 + delta), anchor: location, baseFitRect: baseFitRect, containerSize: geometry.size)
                }

                if zoomScale > minZoom + 0.01 {
                    Text("\(Int(zoomScale * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.thinMaterial, in: Capsule())
                        .padding(12)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomTrailing)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .padding()
    }

    private static func aspectFitRect(imageSize: CGSize, in containerSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: (containerSize.width - fittedSize.width) / 2, y: (containerSize.height - fittedSize.height) / 2)
        return CGRect(origin: origin, size: fittedSize)
    }

    /// The rect the image is actually drawn in right now, given the plain 1x `baseFitRect` and the
    /// current `zoomScale`/`panOffset` — mirrors `ZoomPanState.apply(to:)`, needed here to solve for
    /// where the cursor sits within the *currently displayed* image when anchoring a new zoom.
    private func zoomedFitRect(baseFitRect: CGRect) -> CGRect {
        let scaledSize = CGSize(width: baseFitRect.width * zoomScale, height: baseFitRect.height * zoomScale)
        let center = CGPoint(x: baseFitRect.midX + panOffset.width, y: baseFitRect.midY + panOffset.height)
        return CGRect(x: center.x - scaledSize.width / 2, y: center.y - scaledSize.height / 2, width: scaledSize.width, height: scaledSize.height)
    }

    /// Sets zoom to `newScale` (clamped to `minZoom...maxZoom`) while keeping the image point
    /// currently under `anchor` fixed on screen — same solve as `ZoomPanState.magnify(by:anchor:baseFitRect:)`:
    /// writing `u` for `anchor`'s fractional position within the *old* zoomed rect, the new center
    /// must satisfy `newCenter + newSize*(0.5 - u) == anchor`.
    private func setZoom(_ newScale: CGFloat, anchor: CGPoint, baseFitRect: CGRect, containerSize: CGSize) {
        guard baseFitRect.width > 0, baseFitRect.height > 0 else { return }
        let oldFitRect = zoomedFitRect(baseFitRect: baseFitRect)
        guard oldFitRect.width > 0, oldFitRect.height > 0 else { return }
        let u = CGPoint(x: (anchor.x - oldFitRect.minX) / oldFitRect.width, y: (anchor.y - oldFitRect.minY) / oldFitRect.height)
        let clampedScale = min(maxZoom, max(minZoom, newScale))
        guard clampedScale > minZoom + 0.001 else {
            zoomScale = minZoom
            panOffset = .zero
            return
        }
        let newSize = CGSize(width: baseFitRect.width * clampedScale, height: baseFitRect.height * clampedScale)
        let newCenter = CGPoint(x: anchor.x + newSize.width * (0.5 - u.x), y: anchor.y + newSize.height * (0.5 - u.y))
        zoomScale = clampedScale
        panOffset = clampedPan(
            CGSize(width: newCenter.x - baseFitRect.midX, height: newCenter.y - baseFitRect.midY),
            zoom: clampedScale, containerSize: containerSize
        )
    }

    /// Clamps `offset` so the zoomed image never pans far enough to leave a gap between its edge
    /// and the container's — computed from the aspect-fit size at `zoom == 1`, not `imageSize`
    /// directly, since the image is letterboxed to fit the container before any zoom is applied.
    private func clampedPan(_ offset: CGSize, zoom: CGFloat, containerSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0, containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }
        let fitScale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        let displayedSize = CGSize(width: imageSize.width * fitScale * zoom, height: imageSize.height * fitScale * zoom)
        let maxX = max(0, (displayedSize.width - containerSize.width) / 2)
        let maxY = max(0, (displayedSize.height - containerSize.height) / 2)
        return CGSize(
            width: min(max(offset.width, -maxX), maxX),
            height: min(max(offset.height, -maxY), maxY)
        )
    }
}
