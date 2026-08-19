import SwiftUI
import PhotoCatalog
import RawEngine

/// White Balance + Color Balance RGB (4 wheels) side by side with Color Zones EQ — two sibling
/// panels, each with its own reset/enabled-toggle, rather than one nested under the other,
/// separated by spacing alone (no `Divider` — see the `.fixedSize` note on `body` for why).
/// Color Balance RGB keeps a text header; Color Zones doesn't — its channel switcher carries the
/// reset/toggle instead, see `colorZonesSection`'s doc comment.
/// Everything here adjusts color rather than tone, grouped together regardless of which module
/// (native `CIRAWFilter` input vs. `ColorBalanceRGBParameters` vs. `ColorZonesParameters`)
/// actually produces it. A genuine separate `View` type from `EditorSidebarView` so dragging a
/// wheel, fader, or the Color Zones curve doesn't re-diff the Exposure/Filmic/RGB Curve sidebar,
/// and vice versa. See `EditorRenderCoordinator`'s doc comment for why that split matters, and
/// `ColorWheelHost` for the further per-wheel split.
///
/// Lives in a full-width bottom bar rather than the sidebar — the 4 wheels read much better with
/// room to breathe in a single row (matches how DaVinci Resolve lays its own color wheels out)
/// than cramped into a 320pt-wide column.
struct ColorBalanceBarView: View {
    let asset: PhotoAsset
    let coordinator: EditorRenderCoordinator
    let wheelDiameter: CGFloat

    /// Which of the 3 color-zones curves is currently shown in the EQ graph. 2 (hue) matches
    /// darktable's own default "select by" channel.
    @State private var colorZonesChannel = 2

    var body: some View {
        // `.fixedSize(vertical:)` pins this to its own ideal content height regardless of what
        // the parent `VStack` proposes — without it, this `HStack` was greedily claiming leftover
        // window height instead of leaving it to `EditorView`'s `HSplitView`, leaving a dead
        // `sidebarBackground` gap below the actual content once a `Divider` (since removed, but
        // this guard is cheap insurance against the same failure mode returning) was in the mix.
        HStack(alignment: .top, spacing: 32) {
            colorBalanceSection
            colorZonesSection
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .toggleStyle(.switch)
        .disabled(!coordinator.isReady)
        .background(Color.sidebarBackground)
    }

    private var colorBalanceSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 4) {
                Text("Color Balance RGB")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                resetButton(disabled: !colorBalanceHasEdits(asset), action: {
                    resetColorBalance(asset)
                    coordinator.scheduleRender(params: rawEditParameters(for: asset))
                })
                Spacer()
                Toggle("", isOn: boolBind(\.editColorBalanceEnabled))
                    .labelsHidden()
                    .controlSize(.small)
            }

            HStack(alignment: .top, spacing: 28) {
                HStack(alignment: .top, spacing: 20) {
                    verticalGradientSlider(
                        "Temp", value: bind(\.editNeutralTemperature, fallback: coordinator.renderer.defaultNeutralTemperature),
                        range: 2000...12000, gradient: .neutralTemperature,
                        valueText: "\(Int((asset.editNeutralTemperature ?? coordinator.renderer.defaultNeutralTemperature).rounded()))K",
                        resetValue: coordinator.renderer.defaultNeutralTemperature
                    )
                    verticalGradientSlider(
                        "Tint", value: bind(\.editNeutralTint, fallback: coordinator.renderer.defaultNeutralTint),
                        range: -150...150, gradient: .neutralTint,
                        valueText: formattedTint(asset.editNeutralTint ?? coordinator.renderer.defaultNeutralTint),
                        resetValue: coordinator.renderer.defaultNeutralTint
                    )
                }

                // Wheel edge = darktable's own GUI "soft range" per zone, not the parameter's
                // hard 0...1 max — see ColorWheelControl's doc comment.
                // Negative: each wheel's own bounding box now includes empty margin on all
                // sides to fit the luminance arc (which only actually draws on the right side),
                // so naive positive HStack spacing double-counts that margin between wheels and
                // reads as a huge gap. This pulls the boxes back together to what's visually a
                // normal gap between the arcs and the next wheel, then opens it up by 10pt more
                // than the tightest fit. It's a constant regardless of `wheelDiameter` — the
                // per-wheel margin `wheelDiameter` bakes in (`ColorWheelControl.containerSize -
                // diameter`) doesn't depend on diameter.
                HStack(spacing: -10) {
                    wheel(
                        "Global",
                        y: \.editColorBalanceGlobalY, c: \.editColorBalanceGlobalC, h: \.editColorBalanceGlobalH,
                        maxChroma: 0.01, yRange: -0.05...0.05
                    )
                    wheel(
                        "Shadows",
                        y: \.editColorBalanceShadowsY, c: \.editColorBalanceShadowsC, h: \.editColorBalanceShadowsH,
                        maxChroma: 0.5, yRange: -1...1
                    )
                    wheel(
                        "Midtones",
                        y: \.editColorBalanceMidtonesY, c: \.editColorBalanceMidtonesC, h: \.editColorBalanceMidtonesH,
                        maxChroma: 0.1, yRange: -0.25...0.25
                    )
                    wheel(
                        "Highlights",
                        y: \.editColorBalanceHighlightsY, c: \.editColorBalanceHighlightsC, h: \.editColorBalanceHighlightsH,
                        maxChroma: 0.2, yRange: -0.5...0.5
                    )
                }

                HStack(alignment: .top, spacing: 26) {
                    // No value pill for now — see `verticalGradientSlider`'s doc comment; an
                    // empty `valueText` skips it rather than rendering a blank box. Their 2-
                    // decimal-place values ("−0.50", "45.00") were overflowing the pill and
                    // wrapping; Temp/Tint above don't have that problem, so they keep theirs.
                    verticalGradientSlider(
                        "Chr", value: bind(\.editColorBalanceChromaGlobal, fallback: 0),
                        range: -0.5...0.5, gradient: .colorIntensity,
                        valueText: ""
                    )
                    verticalGradientSlider(
                        "Vib", value: bind(\.editColorBalanceVibrance, fallback: 0),
                        range: -0.5...0.5, gradient: .colorIntensity,
                        valueText: ""
                    )
                    verticalGradientSlider(
                        "Sat", value: bind(\.editFilmicSaturation, fallback: FilmicRGBParameters.darktableDefault.saturation),
                        range: -100...100, gradient: .colorIntensity,
                        valueText: "", resetValue: FilmicRGBParameters.darktableDefault.saturation
                    )
                }
            }
        }
    }

    private func wheel(
        _ title: String,
        y: ReferenceWritableKeyPath<PhotoAsset, Double?>,
        c: ReferenceWritableKeyPath<PhotoAsset, Double?>,
        h: ReferenceWritableKeyPath<PhotoAsset, Double?>,
        maxChroma: Double,
        yRange: ClosedRange<Double>
    ) -> some View {
        ColorWheelHost(
            title: title,
            hue: asset[keyPath: h] ?? 0,
            chroma: asset[keyPath: c] ?? 0,
            luminance: asset[keyPath: y] ?? 0,
            maxChroma: maxChroma,
            yRange: yRange,
            diameter: wheelDiameter,
            onHueChange: { newValue in
                asset[keyPath: h] = newValue
                coordinator.scheduleRender(params: rawEditParameters(for: asset))
            },
            onChromaChange: { newValue in
                asset[keyPath: c] = newValue
                coordinator.scheduleRender(params: rawEditParameters(for: asset))
            },
            onLuminanceChange: { newValue in
                asset[keyPath: y] = newValue
                coordinator.scheduleRender(params: rawEditParameters(for: asset))
            }
        )
        .equatable()
    }

    private func formattedTint(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        return rounded > 0 ? "+\(rounded)" : "\(rounded)"
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

    /// The EQ-style color zones interface: 3 curves (lightness/chroma/hue), each a function of
    /// the pixel's own hue — a tab per curve, one graph shown at a time. A sibling panel to
    /// `colorBalanceSection`, not nested inside it — still placed next to it since both are
    /// hue-driven grading tools (see `ColorZonesParameters`'s scope note: this always operates in
    /// darktable's "select by hue" mode). No standalone "Color Zones" title: the channel switcher
    /// carries the reset/enabled controls that title's row used to hold, styled flush against the
    /// graph (`topCornersSquared`, zero spacing, shared background) so the two read as one card.
    private var colorZonesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $colorZonesChannel) {
                    Text("Lightness").tag(0)
                    Text("Chroma").tag(1)
                    Text("Hue").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                resetButton(disabled: !colorZonesHasEdits(asset), action: {
                    resetColorZones(asset)
                    coordinator.scheduleRender(params: rawEditParameters(for: asset))
                })
                Toggle("", isOn: boolBind(\.editColorZonesEnabled))
                    .labelsHidden()
                    .controlSize(.small)
            }
            .padding(8)
            .background(Color.primary.opacity(0.05))
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 4))

            CurveEditorHost(
                points: colorZonesPoints(for: asset, colorZonesActiveKeyPath),
                title: colorZonesChannelTitle,
                height: 260,
                identityPoints: ColorZonesParameters.identityPoints,
                maxPoints: ColorZonesKernel.maxNodes,
                splineType: .catmullRom,
                referenceIsFlat: true,
                histogram: coordinator.hueHistogram,
                showHueAxis: true,
                showHeader: false,
                topCornersSquared: true,
                onPointsChange: { newPoints in
                    let keyPath = colorZonesActiveKeyPath
                    asset[keyPath: keyPath] = newPoints.flatMap { [$0.x, $0.y] }
                    coordinator.scheduleRender(params: rawEditParameters(for: asset))
                }
            )
            .equatable()
        }
        .frame(width: 620)
    }

    private var colorZonesChannelTitle: String {
        switch colorZonesChannel {
        case 0: return "Lightness vs. Hue"
        case 1: return "Chroma vs. Hue"
        default: return "Hue vs. Hue"
        }
    }

    private var colorZonesActiveKeyPath: ReferenceWritableKeyPath<PhotoAsset, [Double]?> {
        switch colorZonesChannel {
        case 0: return \.editColorZonesLightnessPoints
        case 1: return \.editColorZonesChromaPoints
        default: return \.editColorZonesHuePoints
        }
    }
}
