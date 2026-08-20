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

    init(asset: PhotoAsset, onSelectAsset: @escaping (PhotoAsset) -> Void) {
        self.asset = asset
        self.onSelectAsset = onSelectAsset
        let single = asset.singleStage
        _selectedStage = State(initialValue: single)
        _activeStages = State(initialValue: activeStageStack(for: asset))
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                SessionFilmstripView(asset: asset, onSelectAsset: onSelectAsset)

                StagesSidebarView(
                    asset: asset, selectedStage: $selectedStage, activeStages: $activeStages, coordinator: coordinator,
                    onSelectAsset: onSelectAsset
                )
                .frame(minWidth: 160, idealWidth: 200, maxWidth: 280)

                ZStack {
                    Color.black
                    if let previewImage = coordinator.previewImage {
                        Image(decorative: previewImage, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding()
                    } else {
                        ProgressView("Decoding RAW…")
                            .tint(.white)
                            .foregroundStyle(.white)
                    }
                }
                .frame(minWidth: 480, minHeight: 400)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                EditorSidebarView(asset: asset, stage: selectedStage, activeStages: activeStages, coordinator: coordinator)
            }

            ColorBalanceBarView(
                asset: asset, stage: selectedStage, activeStages: activeStages, coordinator: coordinator,
                wheelDiameter: wheelDiameter
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: asset.filePath) {
            await coordinator.loadAndRender(
                url: asset.resolvedURL(),
                baseParams: rawBaseParameters(for: asset),
                stageStack: activeStages.map(stageParameters(for:))
            )
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
