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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var coordinator = EditorRenderCoordinator()

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
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

                EditorSidebarView(asset: asset, coordinator: coordinator)
            }

            ColorBalanceBarView(asset: asset, coordinator: coordinator, wheelDiameter: wheelDiameter)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(asset.fileName)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    try? modelContext.save()
                    dismiss()
                }
            }
        }
        .task(id: asset.filePath) {
            await coordinator.loadAndRender(url: asset.resolvedURL(), params: rawEditParameters(for: asset))
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
