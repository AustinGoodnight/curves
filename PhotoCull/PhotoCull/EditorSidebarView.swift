import SwiftUI
import PhotoCatalog
import RawEngine

/// Exposure, Detail, Color Balance RGB's Contrast slider, Filmic RGB, and RGB Curve controls — a
/// genuine separate `View` type (not a computed property on `EditorView`) so dragging any one of
/// these sliders only re-diffs this cluster, not the color wheels, Temp/Tint/Chroma/Vibrance/
/// Saturation faders, or Color Zones curve living in `ColorBalanceBarView`. See
/// `EditorRenderCoordinator`'s doc comment for why that split matters. White Balance, the Color
/// Balance wheels, Chroma, Vibrance, and Filmic's Saturation all live in `ColorBalanceBarView`
/// instead, as vertical faders next to the wheels — the sidebar/bar split was never a strict
/// module boundary; Contrast is the one Color Balance RGB field that stayed here.
struct EditorSidebarView: View {
    let asset: PhotoAsset
    let coordinator: EditorRenderCoordinator

    /// Purely local UI state, not persisted: reopening the editor always starts collapsed, since
    /// "most of the time I leave it at default" was the whole reason for hiding it.
    @State private var isFilmicExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                section("Exposure") {
                    slider(
                        "Exposure", value: bind(\.editExposure, fallback: coordinator.renderer.defaultExposure),
                        range: -4...4, resetValue: coordinator.renderer.defaultExposure
                    )
                }
                if coordinator.isReady && coordinator.renderer.isSharpnessSupported {
                    section("Detail") {
                        slider(
                            "Sharpness", value: bind(\.editSharpnessAmount, fallback: coordinator.renderer.defaultSharpnessAmount),
                            range: 0...1, resetValue: coordinator.renderer.defaultSharpnessAmount
                        )
                    }
                }
                // Just Contrast — Chroma/Vibrance moved to `ColorBalanceBarView`'s
                // `colorBalanceSection` as vertical faders next to the wheels, alongside
                // Saturation from Filmic RGB below. Contrast stays here since it wasn't part of
                // that move.
                section("Color Balance RGB") {
                    slider("Contrast", value: bind(\.editColorBalanceContrast, fallback: 0), range: -0.5...0.5)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text("Filmic RGB")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        resetButton(disabled: !filmicHasEdits(asset), action: {
                            resetFilmic(asset)
                            coordinator.scheduleRender(params: rawEditParameters(for: asset))
                        })
                        Spacer()
                        Button {
                            isFilmicExpanded.toggle()
                        } label: {
                            Text("Edit")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        Toggle("", isOn: boolBind(\.editFilmicEnabled))
                            .labelsHidden()
                            .controlSize(.small)
                    }
                    if isFilmicExpanded {
                        let d = FilmicRGBParameters.darktableDefault
                        slider(
                            "White EV", value: bind(\.editFilmicWhitePointSource, fallback: d.whitePointSource),
                            range: 2...8, resetValue: d.whitePointSource
                        )
                        slider(
                            "Black EV", value: bind(\.editFilmicBlackPointSource, fallback: d.blackPointSource),
                            range: -14 ... -2, resetValue: d.blackPointSource
                        )
                        slider(
                            "Contrast", value: bind(\.editFilmicContrast, fallback: d.contrast),
                            range: 0.5...2, resetValue: d.contrast
                        )
                        slider(
                            "Latitude", value: bind(\.editFilmicLatitude, fallback: d.latitude),
                            range: 0.01...80, resetValue: d.latitude
                        )
                        slider(
                            "Balance", value: bind(\.editFilmicBalance, fallback: d.balance),
                            range: -50...50, resetValue: d.balance
                        )
                    }
                }
                section("RGB Curve", resetDisabled: !rgbCurveHasEdits(asset), onReset: {
                    resetRGBCurve(asset)
                    coordinator.scheduleRender(params: rawEditParameters(for: asset))
                }, enabled: boolBind(\.editRGBCurveEnabled)) {
                    CurveEditorHost(
                        points: rgbCurvePoints(for: asset), height: 200,
                        histogram: coordinator.luminanceHistogram,
                        onPointsChange: { newPoints in
                            asset.editRGBCurvePoints = newPoints.flatMap { [$0.x, $0.y] }
                            coordinator.scheduleRender(params: rawEditParameters(for: asset))
                        }
                    )
                    .equatable()
                    Toggle("Preserve Color", isOn: Binding(
                        get: { asset.editRGBCurvePreserveColors ?? true },
                        set: { asset.editRGBCurvePreserveColors = $0; coordinator.scheduleRender(params: rawEditParameters(for: asset)) }
                    ))
                }
                EditorFooterActions(asset: asset, coordinator: coordinator)
            }
            .padding()
        }
        .background(Color.workspaceBackground)
        .toggleStyle(.switch)
        .disabled(!coordinator.isReady)
        .frame(width: 320)
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<PhotoAsset, Double?>, fallback: Double) -> Binding<Double> {
        Binding(
            get: { asset[keyPath: keyPath] ?? fallback },
            set: { newValue in
                asset[keyPath: keyPath] = newValue
                coordinator.scheduleRender(params: rawEditParameters(for: asset))
            }
        )
    }

    private func boolBind(_ keyPath: ReferenceWritableKeyPath<PhotoAsset, Bool>) -> Binding<Bool> {
        Binding(
            get: { asset[keyPath: keyPath] },
            set: { newValue in
                asset[keyPath: keyPath] = newValue
                coordinator.scheduleRender(params: rawEditParameters(for: asset))
            }
        )
    }
}
