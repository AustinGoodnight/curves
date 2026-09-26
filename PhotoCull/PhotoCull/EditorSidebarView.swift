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
    @Environment(ColorSchemeStore.self) private var uiColors
    @AppStorage(AppSettingsKey.developerMode) private var developerMode = false

    /// Purely local UI state, not persisted: reopening the editor always starts closed, since
    /// "most of the time I leave it at default" was the whole reason for hiding these behind a
    /// dropdown in the first place.
    @State private var isToneMapperPopoverPresented = false

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
                // Whole-image readout, not an editable control — no `section()` reset/enabled
                // chrome, just a plain caption label, matching how the per-module histogram
                // backdrops (`CurveEditorControl`'s) are captioned nowhere at all since they sit
                // behind a graph that's already self-explanatory; this needs the label since nothing
                // else on screen explains what it's showing.
                //
                // Color Graph (`ColorDensityWheel`) used to share this row — pulled out for now
                // (not deleted: `ColorDensityWheel.swift` is untouched, still a working, reusable
                // component) so Histogram can take the full row width and grow, instead of the two
                // splitting it.
                VStack(alignment: .leading, spacing: 8) {
                    sectionTitle("Histogram", enabled: nil)
                    RGBHistogramView(data: coordinator.rgbHistogram, height: 240)
                        .frame(maxWidth: .infinity)
                }
                // Exposure (native `CIRAWFilter` input, asset-level) and Contrast (a Color
                // Balance RGB field, per-stage) share one section despite coming from different
                // params — both are basic tone controls. No section title (each `slider(...)`
                // already carries its own name, and a section header reading "Exposure" right
                // above a slider *also* labeled "Exposure" was a redundant duplicate, not a
                // meaningful group label). Chroma/Vibrance, Color Balance RGB's other two "plain
                // slider" fields, stayed in `ColorBalanceBarView`'s `colorBalanceSection` instead
                // (vertical faders next to the wheels) since those read as color controls, not tone.
                section(nil) {
                    // `trackStyle: .hairline, thumbShape: .diamond` — the "Hairline · Diamond"
                    // style picked from the comparison row below, now live on the real controls.
                    slider(
                        "Exposure", value: bind(\.editExposure, fallback: coordinator.renderer.defaultExposure),
                        range: -4...4, resetValue: coordinator.renderer.defaultExposure,
                        ticks: [-4, -3, -2, -1, 0, 1, 2, 3, 4], trackStyle: .hairline, thumbShape: .diamond
                    )
                    slider(
                        "Contrast", value: stageBind(\.editColorBalanceContrast, fallback: 0, module: colorBalanceGate), range: -0.5...0.5,
                        ticks: [-0.5, -0.25, 0, 0.25, 0.5], trackStyle: .hairline, thumbShape: .diamond
                    )
                }
                // Same recessed rounded box as the Balance/Detail knob rows further down.
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
                .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
                // Developer Mode only — photo-aware Exposure and White Balance candidates from
                // `ImageAwareControls.swift`, bound to the real fields and fed live render data, so
                // they can be judged on actual photos.
                if developerMode {
                    devComparisonPanel("Exposure Styles") {
                        styleOption("A · Clip-Warning Ends") {
                            ExposureClipEndsSlider(
                                value: exposureBinding, range: -4...4,
                                resetValue: coordinator.renderer.defaultExposure, stats: coordinator.toneStats
                            )
                        }
                        styleOption("B · Histogram Track") {
                            ExposureHistogramTrack(
                                value: exposureBinding, range: -4...4, resetValue: coordinator.renderer.defaultExposure,
                                histogram: coordinator.luminanceHistogram, stats: coordinator.toneStats
                            )
                        }
                        styleOption("C · Scrub + Sparkline") {
                            ExposureScrubSparkline(
                                value: exposureBinding, range: -4...4, resetValue: coordinator.renderer.defaultExposure,
                                histogram: coordinator.luminanceHistogram, stats: coordinator.toneStats
                            )
                        }
                    }
                    devComparisonPanel("White Balance Styles") {
                        styleOption("A · As-Shot Marker") {
                            WhiteBalanceAsShotSliders(
                                temperature: temperatureBinding, tint: tintBinding,
                                asShotTemperature: coordinator.renderer.defaultNeutralTemperature,
                                asShotTint: coordinator.renderer.defaultNeutralTint
                            )
                        }
                        styleOption("B · Cast Meter") {
                            WhiteBalanceCastMeter(
                                temperature: temperatureBinding, tint: tintBinding,
                                asShotTemperature: coordinator.renderer.defaultNeutralTemperature,
                                asShotTint: coordinator.renderer.defaultNeutralTint,
                                stats: coordinator.toneStats
                            )
                        }
                    }
                }
                // Filmic and AgX are alternative tone mappers for the same pipeline slot (see
                // `RawImageRenderer.applyStage(_:to:)`), so a single 3-way picker replaces what
                // used to be Filmic's own bespoke on/off button — "choose one of the other" reads
                // more honestly as one picker than two independently-toggleable rows that happen
                // to fight over the same slot. The picker is `ToneMapperCurveCarousel` (chosen from
                // the Developer Mode comparison of `ToneMapperPickerStyles.swift`) — the selected
                // mode's tone curve, with ‹ › to step between them. The chevron popover pattern is unchanged
                // (same "hide it, most of the time I leave it at default" reasoning as before),
                // just showing whichever module's sliders match the current picker selection.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        // No background of its own — this row's recessed fill below is the box.
                        ToneMapperCurveCarousel(selection: toneMapperBinding, drawsBackground: false)

                        if toneMapper(for: stage) != .off {
                            Button {
                                isToneMapperPopoverPresented = true
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .popover(isPresented: $isToneMapperPopoverPresented) {
                                if toneMapper(for: stage) == .filmic {
                                    let d = FilmicRGBParameters.darktableDefault
                                    VStack(alignment: .leading, spacing: 10) {
                                        slider(
                                            "White EV", value: stageBind(\.editFilmicWhitePointSource, fallback: d.whitePointSource, module: filmicGate),
                                            range: 2...8, resetValue: d.whitePointSource,
                                            ticks: [2, 3, 4, 5, 6, 7, 8]
                                        )
                                        slider(
                                            "Black EV", value: stageBind(\.editFilmicBlackPointSource, fallback: d.blackPointSource, module: filmicGate),
                                            range: -14 ... -2, resetValue: d.blackPointSource,
                                            ticks: [-14, -12, -10, -8, -6, -4, -2]
                                        )
                                        slider(
                                            "Contrast", value: stageBind(\.editFilmicContrast, fallback: d.contrast, module: filmicGate),
                                            range: 0.5...2, resetValue: d.contrast,
                                            ticks: [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
                                        )
                                        slider(
                                            "Latitude", value: stageBind(\.editFilmicLatitude, fallback: d.latitude, module: filmicGate),
                                            range: 0.01...80, resetValue: d.latitude,
                                            ticks: [0, 20, 40, 60, 80]
                                        )
                                        slider(
                                            "Balance", value: stageBind(\.editFilmicBalance, fallback: d.balance, module: filmicGate),
                                            range: -50...50, resetValue: d.balance,
                                            ticks: [-50, -25, 0, 25, 50]
                                        )
                                    }
                                    .padding()
                                    .frame(width: 260)
                                } else {
                                    let d = AgXParameters.darktableDefault
                                    VStack(alignment: .leading, spacing: 10) {
                                        slider(
                                            "White EV", value: stageBind(\.editAgXWhitePointSource, fallback: d.whiteRelativeEV, module: agxGate),
                                            range: 2...12, resetValue: d.whiteRelativeEV,
                                            ticks: [2, 4, 6, 8, 10, 12]
                                        )
                                        slider(
                                            "Black EV", value: stageBind(\.editAgXBlackPointSource, fallback: d.blackRelativeEV, module: agxGate),
                                            range: -16 ... -2, resetValue: d.blackRelativeEV,
                                            ticks: [-16, -12, -8, -4, -2]
                                        )
                                        slider(
                                            "Contrast", value: stageBind(\.editAgXContrast, fallback: d.contrast, module: agxGate),
                                            range: 1...6, resetValue: d.contrast,
                                            ticks: [1, 2, 3, 4, 5, 6]
                                        )
                                        slider(
                                            "Slope", value: stageBind(\.editAgXSlope, fallback: d.lookSlope, module: agxGate),
                                            range: 0...2, resetValue: d.lookSlope,
                                            ticks: [0, 0.5, 1, 1.5, 2]
                                        )
                                        slider(
                                            "Lift", value: stageBind(\.editAgXLift, fallback: d.lookLift, module: agxGate),
                                            range: -0.5...0.5, resetValue: d.lookLift,
                                            ticks: [-0.5, -0.25, 0, 0.25, 0.5]
                                        )
                                        slider(
                                            "Brightness", value: stageBind(\.editAgXBrightness, fallback: d.lookBrightness, module: agxGate),
                                            range: 0.25...4, resetValue: d.lookBrightness,
                                            ticks: [0.25, 1, 2, 3, 4]
                                        )
                                        slider(
                                            "Saturation", value: stageBind(\.editAgXSaturation, fallback: d.lookSaturation, module: agxGate),
                                            range: 0...2, resetValue: d.lookSaturation,
                                            ticks: [0, 0.5, 1, 1.5, 2]
                                        )
                                        slider(
                                            "Hue Preservation", value: stageBind(\.editAgXHueMix, fallback: d.lookHueMixRatio, module: agxGate),
                                            range: 0...1, resetValue: d.lookHueMixRatio,
                                            ticks: [0, 0.25, 0.5, 0.75, 1]
                                        )
                                    }
                                    .padding()
                                    .frame(width: 260)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                // `uiColors.recessedTrackBackground` — the same fixed dark fill every slider track
                // and the Curve graph use, so this row reads as one more recessed panel in the same
                // family instead of its own, differently-styled control. The carousel
                // itself carries the on/off/which-module signal now, so there's no separate
                // foreground-color toggle state to apply to the row as a whole.
                .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
                // Developer Mode only — every candidate visualization from
                // `ToneMapperPickerStyles.swift`, all live and bound to the same selection, so one
                // can be picked. (Also shown in the Component Gallery.)
                if developerMode {
                    devComparisonPanel("Tone Mapper Styles") {
                        styleOption("1 · Sliding Pill") { ToneMapperSlidingPill(selection: toneMapperBinding) }
                        styleOption("2 · Curve Tiles") { ToneMapperCurveTiles(selection: toneMapperBinding) }
                        styleOption("3 · Rolloff Strips") { ToneMapperRolloffStrips(selection: toneMapperBinding) }
                        styleOption("4 · Underline Tabs") { ToneMapperUnderlineTabs(selection: toneMapperBinding) }
                        styleOption("5 · Stoplight Dots") { ToneMapperStoplightDots(selection: toneMapperBinding) }
                        styleOption("6 · Curve Carousel") { ToneMapperCurveCarousel(selection: toneMapperBinding) }
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
                            resetButton(disabled: !rgbCurveHasAdjustments(stage), action: {
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
                                set: { newValue in
                                    let hadAdjustments = rgbCurveGate.hasAdjustments()
                                    stage.editRGBCurvePreserveColors = newValue
                                    syncModuleEnabled(rgbCurveGate, hadAdjustments: hadAdjustments)
                                    scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                                }
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
                        showEndpointControls: true,
                        onPointsChange: { newPoints in
                            let hadAdjustments = rgbCurveGate.hasAdjustments()
                            stage.editRGBCurvePoints = newPoints.flatMap { [$0.x, $0.y] }
                            syncModuleEnabled(rgbCurveGate, hadAdjustments: hadAdjustments)
                            scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                        }
                    )
                    .equatable()
                    // A precise numeric nudge, separate from dragging the graph's own bottom-left
                    // endpoint — small range ("slightly") since this is meant for a fine trim, not
                    // a replacement for Filmic's much wider Black EV control.
                    slider(
                        "Black Lift Precise", value: stageBind(\.editRGBCurveBlackLift, fallback: 0, module: rgbCurveGate),
                        range: 0...0.15, resetValue: 0, ticks: [0, 0.05, 0.1, 0.15]
                    )
                    // The Balance knobs sit in a recessed rounded box — same fill and corner radius
                    // as the Tone Mapper picker row above, spanning the sidebar's width, with a bit
                    // more internal padding so the knobs don't crowd its edges.
                    // Balance (Chroma/Vibrance/Saturation) — moved here from `ColorBalanceBarView`'s
                    // bottom bar as a row of knobs matching the Detail row below. All three read on a
                    // signed −100…+100 scale (Chroma/Vibrance's native ±0.5 × 200). No on/off switch:
                    // `balanceGate` keeps `editBalanceEnabled` synced to whether any has an adjustment,
                    // and `colorBalanceGate` does the same for Color Balance RGB's outer switch.
                    HStack(alignment: .top, spacing: 0) {
                        knob(
                            "Chroma", value: stageBind(
                                \.editColorBalanceChromaGlobal, fallback: 0, module: balanceGate, masterModule: colorBalanceGate
                            ),
                            range: -0.5...0.5, resetValue: 0, valueText: { signedText($0 * 200) }
                        )
                        knob(
                            "Vibrance", value: stageBind(
                                \.editColorBalanceVibrance, fallback: 0, module: balanceGate, masterModule: colorBalanceGate
                            ),
                            range: -0.5...0.5, resetValue: 0, valueText: { signedText($0 * 200) }
                        )
                        knob(
                            "Saturation", value: stageBind(
                                \.editFilmicSaturation, fallback: FilmicRGBParameters.darktableDefault.saturation,
                                module: balanceGate, masterModule: colorBalanceGate
                            ),
                            range: -100...100, resetValue: FilmicRGBParameters.darktableDefault.saturation,
                            valueText: { signedText($0) }
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 4)
                    // Detail (Sharp/Dehaze/Denoise) and Lens Correction — moved here from
                    // `ColorBalanceBarView`'s bottom bar, as one row of the same `KnobControl` the Film
                    // Simulation section uses for LUT Intensity, each with its name and percentage
                    // underneath. No on/off switches: `detailGate` keeps `editDetailEnabled` synced to
                    // whether any of the three has an adjustment, and Lens at 0 turns
                    // `editLensCorrectionEnabled` off (anything above 0 turns it back on, so a disabled
                    // photo reads as 0). Sharpness is a native `CIRAWFilter` input, so it's only shown
                    // when the renderer supports it.
                    HStack(alignment: .top, spacing: 0) {
                        if coordinator.isReady && coordinator.renderer.isSharpnessSupported {
                            knob(
                                "Sharpness", value: bind(
                                    \.editSharpnessAmount, fallback: coordinator.renderer.defaultSharpnessAmount, module: detailGate
                                ),
                                resetValue: coordinator.renderer.defaultSharpnessAmount
                            )
                        }
                        knob("Dehaze", value: stageBind(\.editDehazeAmount, fallback: 0, module: detailGate), resetValue: 0)
                        knob("Denoise", value: bind(\.editDenoiseAmount, fallback: 0, module: detailGate), resetValue: 0)
                        knob(
                            "Lens", value: Binding(
                                get: { asset.editLensCorrectionEnabled ? (asset.editLensCorrectionIntensity ?? 1) : 0 },
                                set: { newValue in
                                    asset.editLensCorrectionEnabled = newValue > 0
                                    asset.editLensCorrectionIntensity = newValue
                                    scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
                                }
                            ),
                            resetValue: 1
                        )
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .background(uiColors.recessedTrackBackground, in: RoundedRectangle(cornerRadius: 8))
                    // Same 14pt gap (the VStack's 10 + 4) as between Black Lift Precise and the
                    // Balance box above.
                    .padding(.top, 4)
                }
            }
            .padding()
        }
        .background(uiColors.sidebarBackground)
        .toggleStyle(.switch)
        .disabled(!coordinator.isReady)
    }

    /// One `KnobControl` column — knob on top with its value readout centered inside the dial, name
    /// centered below. Each column takes an equal share
    /// of the row's width, so however many knobs are shown spread evenly across it. `valueText`
    /// defaults to a 0–100% readout for the 0...1 Detail/Lens knobs.
    private func knob(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double> = 0...1, resetValue: Double,
        valueText: ((Double) -> String)? = nil
    ) -> some View {
        VStack(spacing: 6) {
            KnobControl(value: value, range: range, resetValue: resetValue)
                // The readout sits inside the dial, centered, in a quiet grey so it reads as a
                // label on the dial rather than competing with it. `allowsHitTesting(false)` so a
                // drag starting on the number still reaches the knob underneath.
                .overlay {
                    Text(valueText?(value.wrappedValue) ?? String(format: "%.0f%%", value.wrappedValue * 100))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Signed whole-number readout ("+12", "0", "−30") for the Balance knobs, scaled so all three
    /// read on the same −100…+100 range.
    private func signedText(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
    }

    /// The Off/Filmic/AgX selection — shared by the segmented `Picker` and every candidate style in
    /// the "Tone Mapper Styles" comparison panel.
    private var toneMapperBinding: Binding<ToneMapper> {
        Binding(
            get: { toneMapper(for: stage) },
            set: { newValue in
                setToneMapper(stage, to: newValue)
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            }
        )
    }

    /// A Developer Mode comparison panel — dashed outline so it reads as "not part of the real UI".
    private func devComparisonPanel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle(title, enabled: nil)
            content()
        }
        .padding(12)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(Color.white.opacity(0.2))
        )
    }

    /// One labeled candidate inside a `devComparisonPanel`.
    private func styleOption<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            content()
        }
    }

    private var exposureBinding: Binding<Double> {
        bind(\.editExposure, fallback: coordinator.renderer.defaultExposure)
    }

    private var temperatureBinding: Binding<Double> {
        bind(\.editNeutralTemperature, fallback: coordinator.renderer.defaultNeutralTemperature, module: whiteBalanceGate)
    }

    private var tintBinding: Binding<Double> {
        bind(\.editNeutralTint, fallback: coordinator.renderer.defaultNeutralTint, module: whiteBalanceGate)
    }

    /// `module`, when passed, keeps that module's own bypass switch synced — same as `stageBind`.
    private func bind(
        _ keyPath: ReferenceWritableKeyPath<PhotoAsset, Double?>, fallback: Double, module: ModuleGate? = nil
    ) -> Binding<Double> {
        Binding(
            get: { asset[keyPath: keyPath] ?? fallback },
            set: { newValue in
                let hadAdjustments = module?.hasAdjustments()
                asset[keyPath: keyPath] = newValue
                if let module, let hadAdjustments {
                    syncModuleEnabled(module, hadAdjustments: hadAdjustments)
                }
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            }
        )
    }

    /// `module`, when passed, keeps that module's own bypass switch synced to whether it still has
    /// adjustments after this particular field's write — see `syncModuleEnabled`'s doc comment.
    /// `masterModule`, when passed, is synced in addition to `module` — see
    /// `ColorBalanceBarView.stageBind`'s doc comment (the Balance knobs need both their own inner
    /// switch and Color Balance RGB's outer one kept in sync).
    private func stageBind(
        _ keyPath: ReferenceWritableKeyPath<Stage, Double?>, fallback: Double, module: ModuleGate? = nil,
        masterModule: ModuleGate? = nil
    ) -> Binding<Double> {
        Binding(
            get: { stage[keyPath: keyPath] ?? fallback },
            set: { newValue in
                let hadAdjustments = module?.hasAdjustments()
                let hadMasterAdjustments = masterModule?.hasAdjustments()
                stage[keyPath: keyPath] = newValue
                if let module, let hadAdjustments {
                    syncModuleEnabled(module, hadAdjustments: hadAdjustments)
                }
                if let masterModule, let hadMasterAdjustments {
                    syncModuleEnabled(masterModule, hadAdjustments: hadMasterAdjustments)
                }
                scheduleRender(for: asset, activeStages: activeStages, coordinator: coordinator, history: history)
            }
        )
    }

    /// The Color Balance RGB module's own bypass switch has no `StoplightToggle` of its own in the
    /// UI (see `Stage.editColorBalanceEnabled`'s doc comment) — Contrast is the one field gated
    /// only by it (no Wheels/Balance sub-group), so this keeps it in sync purely for the render-cost
    /// savings `syncModuleEnabled` documents, invisibly to the user.
    private var colorBalanceGate: ModuleGate {
        ModuleGate(hasAdjustments: { colorBalanceHasAdjustments(stage) }, setEnabled: { stage.editColorBalanceEnabled = $0 })
    }

    private var filmicGate: ModuleGate {
        ModuleGate(hasAdjustments: { filmicHasAdjustments(stage) }, setEnabled: { stage.editFilmicEnabled = $0 })
    }

    private var agxGate: ModuleGate {
        ModuleGate(hasAdjustments: { agxHasAdjustments(stage) }, setEnabled: { stage.editAgXEnabled = $0 })
    }

    private var balanceGate: ModuleGate {
        ModuleGate(hasAdjustments: { balanceGroupHasAdjustments(stage) }, setEnabled: { stage.editBalanceEnabled = $0 })
    }

    private var whiteBalanceGate: ModuleGate {
        ModuleGate(hasAdjustments: { whiteBalanceHasAdjustments(asset) }, setEnabled: { asset.editWhiteBalanceEnabled = $0 })
    }

    private var detailGate: ModuleGate {
        ModuleGate(
            hasAdjustments: { detailHasAdjustments(asset: asset, stage: stage) },
            setEnabled: { asset.editDetailEnabled = $0 }
        )
    }

    private var rgbCurveGate: ModuleGate {
        ModuleGate(hasAdjustments: { rgbCurveHasAdjustments(stage) }, setEnabled: { stage.editRGBCurveEnabled = $0 })
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
