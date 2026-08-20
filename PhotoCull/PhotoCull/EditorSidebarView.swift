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
    /// The stage currently selected in `StagesSidebarView` — the four kernel-module controls
    /// below (Color Balance RGB's Contrast, Filmic RGB, RGB Curve) read/write this stage's own
    /// values, blank-slate per stage. Exposure/Detail stay bound to `asset` directly since
    /// they're base params shared by the whole composite, not per-stage.
    let stage: Stage
    /// Cached active stage list, threaded through to `scheduleRender` — see
    /// `EditorView.activeStages`'s doc comment for why this isn't recomputed here.
    let activeStages: [Stage]
    let coordinator: EditorRenderCoordinator

    /// Purely local UI state, not persisted: reopening the editor always starts collapsed, since
    /// "most of the time I leave it at default" was the whole reason for hiding it.
    @State private var isFilmicExpanded = false

    /// The RGB Curve graph's height, proportional to the sidebar's current width so it grows/
    /// shrinks as the split is dragged instead of staying a fixed 260pt regardless of available
    /// room. `- 32` accounts for `body`'s `.padding()` (16pt each side); `0.65` keeps the curve
    /// closer to square than the full width would (a curve editor reads worse very wide and
    /// short); clamped to a sane range so a narrow or very wide sidebar doesn't produce something
    /// unusably short or absurdly tall.
    private func rgbCurveHeight(for sidebarWidth: CGFloat) -> CGFloat {
        min(max((sidebarWidth - 32) * 0.65, 200), 420)
    }

    var body: some View {
        // `GeometryReader` wrapping everything, read directly inline (`geo.size.width` below)
        // rather than round-tripped through a `PreferenceKey`/`.onPreferenceChange` — that
        // pattern has a background-measurement/one-frame-lag pitfall that left `rgbCurveHeight`
        // pinned to its initial value while the sidebar visibly resized around it. Reading
        // `geo.size.width` directly has no such lag: it's live for every layout pass, including
        // mid-drag on `HSplitView`'s divider.
        GeometryReader { geo in
            sidebarContent(width: geo.size.width)
        }
        .frame(minWidth: 320, idealWidth: 420, maxWidth: 640)
    }

    private func sidebarContent(width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // Whole-image readouts, not editable controls — no `section()` reset/enabled
                // chrome, just a plain caption label each, matching how the per-module histogram
                // backdrops (`CurveEditorControl`'s) are captioned nowhere at all since they sit
                // behind a graph that's already self-explanatory; these need the label since nothing
                // else on screen explains what they're showing.
                VStack(alignment: .leading, spacing: 8) {
                    Text("RGB")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    RGBHistogramView(data: coordinator.rgbHistogram)
                }
                VStack(spacing: 8) {
                    Text("Color")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ColorDensityWheel(density: coordinator.colorDensity, diameter: min(200, width * 0.42))
                        .frame(maxWidth: .infinity)
                }
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
                    slider("Contrast", value: stageBind(\.editColorBalanceContrast, fallback: 0), range: -0.5...0.5)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        sectionTitle("Filmic RGB", enabled: stageBoolBind(\.editFilmicEnabled))
                        resetButton(disabled: !filmicHasEdits(stage), action: {
                            resetFilmic(stage)
                            scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator)
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
                        StoplightToggle(isOn: stageBoolBind(\.editFilmicEnabled))
                    }
                    if isFilmicExpanded {
                        let d = FilmicRGBParameters.darktableDefault
                        slider(
                            "White EV", value: stageBind(\.editFilmicWhitePointSource, fallback: d.whitePointSource),
                            range: 2...8, resetValue: d.whitePointSource
                        )
                        slider(
                            "Black EV", value: stageBind(\.editFilmicBlackPointSource, fallback: d.blackPointSource),
                            range: -14 ... -2, resetValue: d.blackPointSource
                        )
                        slider(
                            "Contrast", value: stageBind(\.editFilmicContrast, fallback: d.contrast),
                            range: 0.5...2, resetValue: d.contrast
                        )
                        slider(
                            "Latitude", value: stageBind(\.editFilmicLatitude, fallback: d.latitude),
                            range: 0.01...80, resetValue: d.latitude
                        )
                        slider(
                            "Balance", value: stageBind(\.editFilmicBalance, fallback: d.balance),
                            range: -50...50, resetValue: d.balance
                        )
                    }
                }
                section("RGB Curve", resetDisabled: !rgbCurveHasEdits(stage), onReset: {
                    resetRGBCurve(stage)
                    scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator)
                }, enabled: stageBoolBind(\.editRGBCurveEnabled)) {
                    CurveEditorHost(
                        points: rgbCurvePoints(for: stage), height: rgbCurveHeight(for: width),
                        histogram: coordinator.luminanceHistogram,
                        onPointsChange: { newPoints in
                            stage.editRGBCurvePoints = newPoints.flatMap { [$0.x, $0.y] }
                            scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator)
                        }
                    )
                    .equatable()
                    Toggle("Preserve Color", isOn: Binding(
                        get: { stage.editRGBCurvePreserveColors ?? true },
                        set: { stage.editRGBCurvePreserveColors = $0; scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator) }
                    ))
                }
                EditorFooterActions(asset: asset, stage: stage, activeStages: activeStages, coordinator: coordinator)
            }
            .padding()
        }
        .background(Color.sidebarBackground)
        .toggleStyle(.switch)
        .disabled(!coordinator.isReady)
    }

    private func bind(_ keyPath: ReferenceWritableKeyPath<PhotoAsset, Double?>, fallback: Double) -> Binding<Double> {
        Binding(
            get: { asset[keyPath: keyPath] ?? fallback },
            set: { newValue in
                asset[keyPath: keyPath] = newValue
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator)
            }
        )
    }

    private func stageBind(_ keyPath: ReferenceWritableKeyPath<Stage, Double?>, fallback: Double) -> Binding<Double> {
        Binding(
            get: { stage[keyPath: keyPath] ?? fallback },
            set: { newValue in
                stage[keyPath: keyPath] = newValue
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator)
            }
        )
    }

    private func stageBoolBind(_ keyPath: ReferenceWritableKeyPath<Stage, Bool>) -> Binding<Bool> {
        Binding(
            get: { stage[keyPath: keyPath] },
            set: { newValue in
                stage[keyPath: keyPath] = newValue
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator)
            }
        )
    }
}
