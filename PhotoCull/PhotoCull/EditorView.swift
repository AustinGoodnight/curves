import SwiftUI
import AppKit
import SwiftData
import PhotoCatalog
import RawEngine

/// Assembles the image pane, `EditorSidebarView`, and `ColorBalanceBarView` — deliberately thin.
/// Those two are genuine separate `View` types (not computed properties) specifically so that
/// dragging a control in one doesn't force SwiftUI to re-diff the other; see
/// `EditorRenderCoordinator`'s doc comment for the full story on why that split exists.
struct EditorView: View {
    let asset: PhotoAsset
    /// Threaded down to `SessionFilmstripView` and `StagesSidebarView`'s "Stack" section — both let
    /// you jump to a different photo without leaving the editor. `ContentView` passes its own
    /// `openEditor(for:)` here, the same function the grid uses, so switching photos from either
    /// filmstrip behaves identically to opening one from the grid.
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
                SessionFilmstripView(asset: asset, onSelectAsset: onSelectAsset)

                StagesSidebarView(
                    asset: asset, selectedStage: $selectedStage, activeStages: $activeStages, coordinator: coordinator,
                    history: history,
                    onSelectAsset: onSelectAsset,
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
    @State private var gestureZoomScale: CGFloat = 1
    @State private var gesturePanOffset: CGSize = .zero

    private let minZoom: CGFloat = 1
    private let maxZoom: CGFloat = 8
    private let doubleClickZoom: CGFloat = 2.5

    private var imageSize: CGSize {
        CGSize(width: previewImage.width, height: previewImage.height)
    }

    var body: some View {
        GeometryReader { geometry in
            let effectiveZoom = zoomScale * gestureZoomScale
            Image(decorative: previewImage, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(effectiveZoom)
                .offset(
                    x: panOffset.width + gesturePanOffset.width,
                    y: panOffset.height + gesturePanOffset.height
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            gestureZoomScale = value
                        }
                        .onEnded { value in
                            zoomScale = min(maxZoom, max(minZoom, zoomScale * value))
                            gestureZoomScale = 1
                            panOffset = clampedPan(panOffset, zoom: zoomScale, containerSize: geometry.size)
                        }
                )
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
                        .onEnded { _ in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if zoomScale > minZoom + 0.01 {
                                    zoomScale = minZoom
                                    panOffset = .zero
                                } else {
                                    zoomScale = doubleClickZoom
                                    panOffset = clampedPan(.zero, zoom: doubleClickZoom, containerSize: geometry.size)
                                }
                            }
                        }
                )

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
        .padding()
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
