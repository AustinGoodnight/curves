import SwiftUI
import PhotoCatalog
import RawEngine

/// Exposure, Color Balance RGB's Contrast slider, Filmic RGB, and RGB Curve controls — a genuine
/// separate `View` type (not a computed property on `EditorView`) so dragging any one of these
/// sliders only re-diffs this cluster, not the color wheels, Temp/Tint/Chroma/Vibrance/Saturation/
/// Sharp/Dehaze faders, or Color Zones curve living in `ColorBalanceBarView`. See
/// `EditorRenderCoordinator`'s doc comment for why that split matters. White Balance, the Color
/// Balance wheels, Chroma, Vibrance, Filmic's Saturation, Sharpness, and Dehaze all live in
/// `ColorBalanceBarView` instead, as vertical faders next to the wheels — the sidebar/bar split
/// was never a strict module boundary; Contrast is the one Color Balance RGB field that stayed
/// here.
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
    let history: EditHistory

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
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Histogram")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        RGBHistogramView(data: coordinator.rgbHistogram, height: 160)
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: 8) {
                        Text("Color Graph")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ColorDensityWheel(density: coordinator.colorDensity, diameter: min(160, width * 0.34))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                section("Exposure") {
                    slider(
                        "Exposure", value: bind(\.editExposure, fallback: coordinator.renderer.defaultExposure),
                        range: -4...4, resetValue: coordinator.renderer.defaultExposure
                    )
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
                            scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
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
                VStack(alignment: .leading, spacing: 10) {
                    // Three independent regions, same technique as `ColorBalanceBarView.colorZonesSection`'s
                    // own header — "Curve" + reset pinned leading, "Preserve Color" truly centered on the
                    // row's full width, the module enabled toggle pinned trailing. A single `HStack` with
                    // `Spacer()`s in between would center "Preserve Color" in whatever's left between the
                    // other two instead of on the row as a whole, drifting depending on how wide "Curve"'s
                    // own leading cluster happens to render.
                    ZStack {
                        HStack(spacing: 4) {
                            sectionTitle("Curve", enabled: stageBoolBind(\.editRGBCurveEnabled))
                            resetButton(disabled: !rgbCurveHasEdits(stage), action: {
                                resetRGBCurve(stage)
                                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                            })
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 6) {
                            Text("Preserve Color")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            StoplightToggle(isOn: Binding(
                                get: { stage.editRGBCurvePreserveColors ?? true },
                                set: { stage.editRGBCurvePreserveColors = $0; scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history) }
                            ))
                        }
                        HStack(spacing: 4) {
                            Spacer(minLength: 0)
                            StoplightToggle(isOn: stageBoolBind(\.editRGBCurveEnabled))
                        }
                    }
                    // No inner title/hint/reset row anymore (`showHeader: false`) — "Curve" above already
                    // carries the title and the one reset button that actually matters (this module's full
                    // reset, via `resetRGBCurve`); `CurveEditorControl`'s own built-in header only ever reset
                    // the curve's points, a narrower, redundant second reset button sitting right below the
                    // real one.
                    CurveEditorHost(
                        points: rgbCurvePoints(for: stage), height: rgbCurveHeight(for: width),
                        histogram: coordinator.luminanceHistogram,
                        showHeader: false,
                        onPointsChange: { newPoints in
                            stage.editRGBCurvePoints = newPoints.flatMap { [$0.x, $0.y] }
                            scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                        }
                    )
                    .equatable()
                }
                EditorFooterActions(asset: asset, stage: stage, activeStages: activeStages, coordinator: coordinator, history: history)
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
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            }
        )
    }

    private func stageBind(_ keyPath: ReferenceWritableKeyPath<Stage, Double?>, fallback: Double) -> Binding<Double> {
        Binding(
            get: { stage[keyPath: keyPath] ?? fallback },
            set: { newValue in
                stage[keyPath: keyPath] = newValue
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            }
        )
    }

    private func stageBoolBind(_ keyPath: ReferenceWritableKeyPath<Stage, Bool>) -> Binding<Bool> {
        Binding(
            get: { stage[keyPath: keyPath] },
            set: { newValue in
                stage[keyPath: keyPath] = newValue
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            }
        )
    }
}
